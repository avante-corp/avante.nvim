"""RAG Service API for managing document indexing and retrieval."""

from __future__ import annotations

# Standard library imports
import asyncio
import fcntl
import json
import multiprocessing
import os
import re
import shutil
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from pathlib import Path
from typing import TYPE_CHECKING
from urllib.parse import urljoin, urlparse

# Third-party imports
import chromadb
import httpx
import llama_index.core as li
import pathspec
from chromadb.config import Settings
from fastapi import APIRouter, BackgroundTasks, FastAPI, HTTPException

# Local application imports
from libs.db import init_db
from libs.logger import configure_logging, logger
from libs.utils import (
    get_node_uri,
    inject_uri_to_node,
    is_local_uri,
    is_path_node,
    is_remote_uri,
    path_to_uri,
    uri_to_path,
)
from llama_index.core import (
    SimpleDirectoryReader,
    StorageContext,
    VectorStoreIndex,
    load_index_from_storage,
)
from llama_index.core.node_parser import CodeSplitter, SentenceSplitter
from llama_index.core.postprocessor import MetadataReplacementPostProcessor
from llama_index.core.schema import Document
from llama_index.vector_stores.chroma import ChromaVectorStore
from markdownify import markdownify as md
from models.indexing_history import IndexingHistory
from models.resource import Resource
from providers.factory import initialize_embed_model, initialize_llm_model
from pydantic import BaseModel, Field
from services.indexing_history import indexing_history_service
from services.resource import resource_service
from tree_sitter_language_pack import SupportedLanguage, get_parser
from watchdog.events import FileSystemEvent, FileSystemEventHandler
from watchdog.observers import Observer

if TYPE_CHECKING:
    import argparse
    from collections.abc import AsyncGenerator

    from llama_index.core.data_structs import IndexDict
    from llama_index.core.indices.base import BaseIndex
    from llama_index.core.schema import NodeWithScore, QueryBundle
    from pathspec.gitignore import GitIgnoreSpec
    from watchdog.observers.api import BaseObserver


base_data_dir: Path


DEFAULT_BINARY_EXTENSIONS = [
    # Images
    ".png",
    ".jpg",
    ".jpeg",
    ".gif",
    ".bmp",
    ".ico",
    ".webp",
    ".tiff",
    ".exr",
    ".hdr",
    ".svg",
    ".psd",
    ".ai",
    ".eps",
    # Audio/Video
    ".mp3",
    ".wav",
    ".mp4",
    ".avi",
    ".mov",
    ".webm",
    ".flac",
    ".ogg",
    ".m4a",
    ".aac",
    ".wma",
    ".flv",
    ".mkv",
    ".wmv",
    # Documents
    ".pdf",
    ".doc",
    ".docx",
    ".xls",
    ".xlsx",
    ".ppt",
    ".pptx",
    ".odt",
    # Archives
    ".zip",
    ".tar",
    ".gz",
    ".7z",
    ".rar",
    ".iso",
    ".dmg",
    ".pkg",
    ".deb",
    ".rpm",
    ".msi",
    ".apk",
    ".xz",
    ".bz2",
    # Compiled
    ".exe",
    ".dll",
    ".so",
    ".dylib",
    ".class",
    ".pyc",
    ".o",
    ".obj",
    ".lib",
    ".a",
    ".out",
    ".app",
    ".apk",
    ".jar",
    # Fonts
    ".ttf",
    ".otf",
    ".woff",
    ".woff2",
    ".eot",
    # Other binary
    ".bin",
    ".dat",
    ".db",
    ".sqlite",
    ".db",
    ".DS_Store",
]


def try_acquire_leadership() -> bool:
    """Try to acquire leadership using file lock."""
    try:
        # Lock file for leader election
        lock_file = base_data_dir / "leader.lock"
        # Ensure the lock file exists
        lock_file.parent.mkdir(parents=True, exist_ok=True)
        lock_file.touch(exist_ok=True)

        # Try to acquire an exclusive lock
        lock_fd = os.open(str(lock_file), os.O_RDWR)
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)

        # Write current process ID to lock file
        os.truncate(lock_fd, 0)
        os.write(lock_fd, str(os.getpid()).encode())

        return True
    except OSError:
        return False


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None]:
    """Initialize services on startup."""
    # Try to become leader if no worker_id is set

    is_leader = try_acquire_leadership()

    # Only run initialization in the leader
    if is_leader:
        logger.info("Starting RAG service as leader (PID: %d)...", os.getpid())

        # Get all active resources
        active_resources = [r for r in resource_service.get_all_resources() if r.status == "active"]
        logger.info("Found %d active resources to sync", len(active_resources))

        for resource in active_resources:
            try:
                if is_local_uri(resource.uri):
                    directory = uri_to_path(resource.uri)
                    if not directory.exists():
                        error_msg = f"Directory not found: {directory}"
                        logger.error(error_msg)
                        resource_service.update_resource_status(resource.uri, "error", error_msg)
                        continue

                    # Start file system watcher
                    event_handler = FileSystemHandler(directory=directory)
                    observer = Observer()
                    observer.schedule(event_handler, str(directory), recursive=True)
                    observer.start()
                    watched_resources[resource.uri] = observer

                    # Start indexing
                    await index_local_resource_async(resource)

                elif is_remote_uri(resource.uri):
                    if not is_remote_resource_exists(resource.uri):
                        error_msg = "HTTPS resource not found"
                        logger.error("%s: %s", error_msg, resource.uri)
                        resource_service.update_resource_status(resource.uri, "error", error_msg)
                        continue

                    # Start indexing
                    await index_remote_resource_async(resource)

                logger.debug("Successfully synced resource: %s", resource.uri)

            except (OSError, ValueError, RuntimeError) as e:
                error_msg = f"Failed to sync resource {resource.uri}: {e}"
                logger.exception(error_msg)
                resource_service.update_resource_status(resource.uri, "error", error_msg)

    yield

    # Cleanup on shutdown (only in leader)
    if is_leader:
        for observer in watched_resources.values():
            observer.stop()
            observer.join()


router = APIRouter()

# Constants
SIMILARITY_THRESHOLD = 0.95
MAX_SAMPLE_SIZE = 100
BATCH_PROCESSING_DELAY = 1

# number of cpu cores to use for parallel processing
max_workers: int
BATCH_SIZE = 40  # Number of documents to process per batch
DEFAULT_MAX_EMBEDDING_TOKENS = 512

# Global variables
watched_resources: dict[str, BaseObserver]  # Directory path -> Observer instance mapping
file_last_modified: dict[Path, float]  # File path -> Last modified time mapping
index_lock: threading.Lock
index: BaseIndex[IndexDict]
embedding_splitter: SentenceSplitter
max_embedding_tokens: int

code_ext_map: dict[str, SupportedLanguage] = {
    ".py": "python",
    ".js": "javascript",
    ".ts": "typescript",
    ".jsx": "javascript",
    ".tsx": "typescript",
    ".vue": "vue",
    ".go": "go",
    ".java": "java",
    ".cpp": "cpp",
    ".c": "c",
    ".h": "cpp",
    ".rs": "rust",
    ".rb": "ruby",
    ".php": "php",
    ".scala": "scala",
    ".kt": "kotlin",
    ".swift": "swift",
    ".lua": "lua",
    ".pl": "perl",
    ".pm": "perl",
    ".t": "perl",
    ".pm6": "perl",
    ".m": "perl",
}

required_exts = [
    ".txt",
    ".pdf",
    ".docx",
    ".xlsx",
    ".pptx",
    ".rst",
    ".json",
    ".ini",
    ".conf",
    ".toml",
    ".md",
    ".markdown",
    ".csv",
    ".tsv",
    ".html",
    ".htm",
    ".xml",
    ".yaml",
    ".yml",
    ".css",
    ".scss",
    ".less",
    ".sass",
    ".styl",
    ".sh",
    ".bash",
    ".zsh",
    ".fish",
    ".rb",
    ".java",
    ".go",
    ".ts",
    ".tsx",
    ".js",
    ".jsx",
    ".vue",
    ".py",
    ".php",
    ".c",
    ".cpp",
    ".h",
    ".rs",
    ".swift",
    ".kt",
    ".lua",
    ".perl",
    ".pl",
    ".pm",
    ".t",
    ".pm6",
    ".m",
]


http_headers = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36",
}


def is_remote_resource_exists(url: str) -> bool:
    """Check if a URL exists."""
    try:
        response = httpx.head(url, headers=http_headers)
        return response.status_code in {
            httpx.codes.OK,
            httpx.codes.MOVED_PERMANENTLY,
            httpx.codes.FOUND,
        }
    except (OSError, ValueError, RuntimeError) as e:
        logger.error("Error checking if URL exists %s: %s", url, e)
        return False


def fetch_markdown(url: str) -> str:
    """Fetch markdown content from a URL."""
    try:
        logger.info("Fetching markdown content from %s", url)
        response = httpx.get(url, headers=http_headers)
        if response.status_code == int(httpx.codes.OK):
            return md(response.text)
        return ""
    except (OSError, ValueError, RuntimeError) as e:
        logger.error("Error fetching markdown content %s: %s", url, e)
        return ""


def markdown_to_links(base_url: str, markdown: str) -> list[str]:
    """Extract links from markdown content."""
    links = []
    seek = {base_url}
    parsed_url = urlparse(base_url)
    domain = parsed_url.netloc
    scheme = parsed_url.scheme
    for match in re.finditer(r"\[(.*?)\]\((.*?)\)", markdown):
        url = match.group(2)
        if not url.startswith(scheme):
            url = urljoin(base_url, url)
        if urlparse(url).netloc != domain:
            continue
        if url in seek:
            continue
        seek.add(url)
        links.append(url)
    return links


def parse_positive_int(value: str, default: int, setting_name: str) -> int:
    """Parse a positive integer setting, falling back to the provided default."""
    try:
        parsed_value = int(value)
    except (TypeError, ValueError):
        logger.warning("Invalid %s=%r, defaulting to %d", setting_name, value, default)
        return default

    if parsed_value <= 0:
        logger.warning("Invalid %s=%r, defaulting to %d", setting_name, value, default)
        return default

    return parsed_value


class ResourceURIRequest(BaseModel):
    """Request model for resource operations."""

    uri: str = Field(..., description="URI of the resource to watch and index")


class ResourceRequest(ResourceURIRequest):
    """Request model for resource operations."""

    name: str = Field(..., description="Name of the resource to watch and index")


class SourceDocument(BaseModel):
    """Model for source document information."""

    uri: str = Field(..., description="URI of the source")
    content: str = Field(..., description="Content snippet from the document")
    score: float | None = Field(None, description="Relevance score of the document")


class RetrieveRequest(BaseModel):
    """Request model for information retrieval."""

    query: str = Field(
        ...,
        description="The query text to search for in the indexed documents",
    )
    base_uri: str = Field(..., description="The base URI to search in")
    top_k: int | None = Field(5, description="Number of top results to return", ge=1, le=20)


class RetrieveResponse(BaseModel):
    """Response model for information retrieval."""

    response: str = Field(..., description="Generated response to the query")
    sources: list[SourceDocument] = Field(..., description="List of source documents used")


class FileSystemHandler(FileSystemEventHandler):
    """Handler for file system events."""

    def __init__(self: FileSystemHandler, directory: Path) -> None:
        """Initialize the handler."""
        self.directory = directory

    def on_modified(self: FileSystemHandler, event: FileSystemEvent) -> None:
        """Handle file modification events."""
        if not event.is_directory and not str(event.src_path).endswith(".tmp"):
            self.handle_file_change(Path(str(event.src_path)))

    def on_created(self: FileSystemHandler, event: FileSystemEvent) -> None:
        """Handle file creation events."""
        if not event.is_directory and not str(event.src_path).endswith(".tmp"):
            self.handle_file_change(Path(str(event.src_path)))

    def handle_file_change(self: FileSystemHandler, file_path: Path) -> None:
        """Handle changes to a file."""
        current_time = time.time()

        abs_file_path = file_path
        if not Path(abs_file_path).is_absolute():
            abs_file_path = Path(self.directory, file_path)

        # Check if the file was recently processed
        if abs_file_path in file_last_modified and current_time - file_last_modified[abs_file_path] < BATCH_PROCESSING_DELAY:
            return

        file_last_modified[abs_file_path] = current_time
        threading.Thread(target=update_index_for_file, args=(self.directory, abs_file_path)).start()


def is_valid_text(text: str) -> bool:
    """Check if the text is valid and readable."""
    if not text:
        logger.debug("Text content is empty")
        return False

    # Check if the text mainly contains printable characters
    printable_ratio = sum(1 for c in text if c.isprintable() or c in "\n\r\t") / len(text)
    if printable_ratio <= SIMILARITY_THRESHOLD:
        logger.debug("Printable character ratio too low: %.2f%%", printable_ratio * 100)
        # Output a small sample for analysis
        sample = text[:MAX_SAMPLE_SIZE] if len(text) > MAX_SAMPLE_SIZE else text
        logger.debug("Text sample: %r", sample)
    return printable_ratio > SIMILARITY_THRESHOLD


def clean_text(text: str) -> str:
    """Clean text content by removing non-printable characters."""
    return "".join(char for char in text if char.isprintable() or char in "\n\r\t")


def process_document_batch(documents: list[Document]) -> bool:  # noqa: PLR0915, C901, PLR0912, RUF100
    """Process a batch of documents for embedding."""
    try:
        # Filter out invalid and already processed documents
        valid_documents = []
        invalid_documents = []
        for doc in documents:
            doc_id = doc.doc_id

            # Check if document with same hash has already been successfully processed
            status_records = indexing_history_service.get_indexing_status(doc=doc)
            if status_records and status_records[0].status == "completed":
                logger.debug(
                    "Document with same hash already processed, skipping: %s",
                    doc.doc_id,
                )
                continue

            logger.debug("Processing document: %s", doc.doc_id)
            try:
                content = doc.get_content()

                # If content is bytes type, try to decode
                if isinstance(content, bytes):
                    try:
                        content = content.decode("utf-8", errors="replace")
                    except (UnicodeDecodeError, OSError) as e:
                        error_msg = f"Unable to decode document content: {doc_id}, error: {e!s}"
                        logger.warning(error_msg)
                        indexing_history_service.update_indexing_status(doc, "failed", error_message=error_msg)
                        invalid_documents.append(doc_id)
                        continue

                # Ensure content is string type
                content = str(content)

                if not is_valid_text(content):
                    error_msg = f"Invalid document content: {doc_id}"
                    logger.warning(error_msg)
                    indexing_history_service.update_indexing_status(doc, "failed", error_message=error_msg)
                    invalid_documents.append(doc_id)
                    continue

                cleaned_content = clean_text(content)
                metadata = getattr(doc, "metadata", {}).copy()

                new_doc = Document(
                    text=cleaned_content,
                    doc_id=doc_id,
                    metadata=metadata,
                )
                inject_uri_to_node(new_doc)
                valid_documents.append(new_doc)
                # Update status to indexing for valid documents
                indexing_history_service.update_indexing_status(doc, "indexing")

            except OSError as e:
                error_msg = f"Document processing failed: {doc_id}, error: {e!s}"
                logger.exception(error_msg)
                indexing_history_service.update_indexing_status(doc, "failed", error_message=error_msg)
                invalid_documents.append(doc_id)

        try:
            if valid_documents:
                with index_lock:
                    index.refresh_ref_docs(valid_documents)

            # Update status to completed for successfully processed documents
            for doc in valid_documents:
                indexing_history_service.update_indexing_status(
                    doc,
                    "completed",
                    metadata=doc.metadata,
                )

            return not invalid_documents

        except OSError as e:
            error_msg = f"Batch indexing failed: {e!s}"
            logger.exception(error_msg)
            # Update status to failed for all documents in the batch
            for doc in valid_documents:
                indexing_history_service.update_indexing_status(doc, "failed", error_message=error_msg)
            return False

    except OSError as e:
        error_msg = f"Batch processing failed: {e!s}"
        logger.exception(error_msg)
        # Update status to failed for all documents in the batch
        for doc in documents:
            indexing_history_service.update_indexing_status(doc, "failed", error_message=error_msg)
        return False


def get_gitignore_files(directory: Path) -> list[str]:
    """Get patterns from .gitignore file."""
    patterns = []

    # Always include .git/ if it exists
    if (directory / ".git").is_dir():
        patterns.append(".git/")

    # Check for .gitignore
    gitignore_path = directory / ".gitignore"
    if gitignore_path.exists():
        with gitignore_path.open("r", encoding="utf-8") as f:
            patterns.extend(f.readlines())

    return patterns


def get_gitcrypt_files(directory: Path) -> list[str]:
    """Get patterns of git-crypt encrypted files using git command."""
    git_crypt_patterns = []
    git_executable = shutil.which("git")

    if not git_executable:
        logger.warning("git command not found, git-crypt files will not be excluded")
        return git_crypt_patterns

    try:
        # Find git root directory
        git_root_cmd = subprocess.run(
            [git_executable, "-C", str(directory), "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=False,
        )

        if git_root_cmd.returncode != 0:
            logger.warning(
                "Not a git repository or git command failed: %s",
                git_root_cmd.stderr.strip(),
            )
            return git_crypt_patterns

        git_root = Path(git_root_cmd.stdout.strip())

        # Get relative path from git root to our directory
        rel_path = directory.relative_to(git_root) if directory != git_root else Path()

        # Execute git commands separately and pipe the results
        git_ls_files = subprocess.run(
            [git_executable, "-C", str(git_root), "ls-files", "-z"],
            capture_output=True,
            text=False,
            check=False,
        )

        if git_ls_files.returncode != 0:
            return git_crypt_patterns

        # Use Python to process the output instead of xargs, grep, and cut
        git_check_attr = subprocess.run(
            [
                git_executable,
                "-C",
                str(git_root),
                "check-attr",
                "filter",
                "--stdin",
                "-z",
            ],
            input=git_ls_files.stdout,
            capture_output=True,
            text=False,
            check=False,
        )

        if git_check_attr.returncode != 0:
            return git_crypt_patterns

        # Process the output in Python to find git-crypt files
        output = git_check_attr.stdout.decode("utf-8")
        lines = output.split("\0")

        for i in range(0, len(lines) - 2, 3):
            if i + 2 < len(lines) and lines[i + 2] == "git-crypt":
                file_path = lines[i]
                # Only include files that are in our directory or subdirectories
                file_path_obj = Path(file_path)
                if str(rel_path) == "." or file_path_obj.is_relative_to(rel_path):
                    git_crypt_patterns.append(file_path)

        # Log if git-crypt patterns were found
        if git_crypt_patterns:
            logger.debug("Excluding git-crypt encrypted files: %s", git_crypt_patterns)
    except (subprocess.SubprocessError, OSError) as e:
        logger.warning("Error getting git-crypt files: %s", str(e))

    return git_crypt_patterns


def get_pathspec(directory: Path) -> GitIgnoreSpec:
    """Get pathspec for the directory."""
    # Collect patterns from both sources
    patterns = get_gitignore_files(directory)
    patterns.extend(get_gitcrypt_files(directory))
    patterns.extend([".jj"])

    return pathspec.GitIgnoreSpec.from_lines(patterns)


def scan_directory(directory: Path) -> list[str]:
    """Scan directory and return a list of matched files."""
    spec = get_pathspec(directory)
    binary_extensions = DEFAULT_BINARY_EXTENSIONS

    config_home = Path(os.environ.get("XDG_CONFIG_HOME", ""))
    if not config_home.is_absolute():
        config_home = Path.home() / ".config"
    ignore_file = config_home / "avante" / "rag-ignore"
    try:
        ignore_lines = ignore_file.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        pass
    else:
        binary_extensions = [line.strip().lower() for line in ignore_lines if line.strip() and not line.lstrip().startswith("#")]

    matched_files = []

    for root, _, files in os.walk(directory):
        file_paths = [str(Path(root) / file) for file in files]
        for file in file_paths:
            file_ext = Path(file).suffix.lower()
            if file_ext in binary_extensions:
                logger.debug("Skipping binary file: %s", file)
                continue

            if spec and spec.match_file(os.path.relpath(file, directory)):
                logger.debug("Ignoring file: %s", file)
            else:
                matched_files.append(file)

    return matched_files


def update_index_for_file(directory: Path, abs_file_path: Path) -> None:
    """Update the index for a single file."""
    logger.debug("Starting to index file: %s", abs_file_path)

    if not abs_file_path.is_file():
        logger.debug("File does not exist or is not a file, skipping: %s", abs_file_path)
        return

    rel_file_path = abs_file_path.relative_to(directory)

    spec = get_pathspec(directory)
    if spec and spec.match_file(rel_file_path):
        logger.debug("File is ignored, skipping: %s", abs_file_path)
        return

    resource = resource_service.get_resource(path_to_uri(directory))
    if not resource:
        logger.error("Resource not found for directory: %s", directory)
        return

    resource_service.update_resource_indexing_status(resource.uri, "indexing", "")

    documents = SimpleDirectoryReader(
        input_files=[abs_file_path],
        filename_as_id=True,
        required_exts=required_exts,
    ).load_data()

    logger.debug("Updating index: %s", abs_file_path)
    processed_documents = split_documents(documents)
    success = process_document_batch(processed_documents)

    if success:
        resource_service.update_resource_indexing_status(resource.uri, "indexed", "")
        logger.debug("File indexing completed: %s", abs_file_path)
    else:
        resource_service.update_resource_indexing_status(resource.uri, "failed", "unknown error")
        logger.error("File indexing failed: %s", abs_file_path)


def split_documents(documents: list[Document]) -> list[Document]:
    """Split documents into code and non-code documents."""
    # Create file parser configuration
    # Initialize CodeSplitter
    # Split code documents using CodeSplitter
    processed_documents = []

    def append_embedding_sized_documents(doc: Document, base_metadata: dict[str, object] | None = None) -> None:
        """Split a document into chunks that fit the embedding model input limit."""
        text = doc.get_content()
        chunks = embedding_splitter.split_text(text)
        metadata = {**doc.metadata, **(base_metadata or {})}
        uri = get_node_uri(doc)
        if uri:
            metadata["uri"] = uri

        for i, chunk in enumerate(chunks):
            chunk_metadata = metadata
            chunk_doc_id = doc.doc_id
            if len(chunks) > 1:
                chunk_metadata = {
                    **metadata,
                    "embedding_chunk_number": i,
                    "embedding_total_chunks": len(chunks),
                    "embedding_max_tokens": max_embedding_tokens,
                }
                chunk_doc_id = f"{doc.doc_id}__embedding_part_{i}"

            processed_documents.append(
                Document(
                    text=chunk,
                    doc_id=chunk_doc_id,
                    metadata=chunk_metadata,
                ),
            )

    for doc in documents:
        uri = get_node_uri(doc)
        if not uri:
            continue
        if not is_path_node(doc):
            append_embedding_sized_documents(doc)
            continue
        file_path = uri_to_path(uri)
        file_ext = file_path.suffix.lower()
        if file_ext in code_ext_map:
            # Apply CodeSplitter to code files
            language = code_ext_map.get(file_ext, "python")
            parser = get_parser(language)
            code_splitter = CodeSplitter(
                language=language,  # Default is python, will auto-detect based on file extension
                chunk_lines=80,  # Maximum number of lines per code block
                chunk_lines_overlap=15,  # Number of overlapping lines to maintain context
                max_chars=1500,  # Maximum number of characters per block
                parser=parser,
            )
            try:
                t = doc.get_content()
                texts = code_splitter.split_text(t)
            except ValueError as e:
                logger.error(
                    "Error splitting document: %s, so skipping split, error: %s",
                    doc.doc_id,
                    str(e),
                )
                processed_documents.append(doc)
                continue

            for i, text in enumerate(texts):
                new_doc = Document(
                    text=text,
                    doc_id=f"{doc.doc_id}__part_{i}",
                    metadata={
                        **doc.metadata,
                        "chunk_number": i,
                        "total_chunks": len(texts),
                        "language": code_splitter.language,
                        "orig_doc_id": doc.doc_id,
                    },
                )
                append_embedding_sized_documents(new_doc)
        else:
            append_embedding_sized_documents(doc, {"orig_doc_id": doc.doc_id})
    return processed_documents


async def index_remote_resource_async(resource: Resource) -> None:
    """Asynchronously index a remote resource."""
    resource_service.update_resource_indexing_status(resource.uri, "indexing", "")
    url = resource.uri
    try:
        logger.debug("Loading resource content: %s", url)

        # Fetch markdown content
        markdown = fetch_markdown(url)

        link_md_pairs = [(url, markdown)]

        # Extract links from markdown
        links = markdown_to_links(url, markdown)

        logger.debug("Found %d sub links", len(links))
        logger.debug("Link list: %s", links)

        # Use thread pool for parallel batch processing
        loop = asyncio.get_event_loop()
        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            mds: list[str] = await loop.run_in_executor(
                executor,
                lambda: list(executor.map(fetch_markdown, links)),
            )

        zipped = zip(links, mds, strict=True)  # pyright: ignore
        link_md_pairs.extend(zipped)

        # Create documents from links
        documents = [Document(text=markdown, doc_id=link) for link, markdown in link_md_pairs]

        logger.debug("Found %d documents", len(documents))
        logger.debug("Document list: %s", [doc.doc_id for doc in documents])

        processed_documents = split_documents(documents)

        # Process documents in batches
        total_documents = len(processed_documents)
        batches = [processed_documents[i : i + BATCH_SIZE] for i in range(0, total_documents, BATCH_SIZE)]
        logger.debug("Splitting documents into %d batches for processing", len(batches))

        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            results = await loop.run_in_executor(
                executor,
                lambda: list(executor.map(process_document_batch, batches)),
            )

        # Check processing results
        if all(results):
            logger.debug("Resource %s indexing completed", url)
            resource_service.update_resource_indexing_status(resource.uri, "indexed", "")
        else:
            failed_batches = len([r for r in results if not r])
            error_msg = f"Some batches failed processing ({failed_batches}/{len(batches)})"
            logger.error(error_msg)
            resource_service.update_resource_indexing_status(resource.uri, "indexed", error_msg)

    except OSError as e:
        error_msg = f"Resource indexing failed: {url}"
        logger.exception(error_msg)
        resource_service.update_resource_indexing_status(resource.uri, "failed", error_msg)
        raise e  # noqa: TRY201


async def index_local_resource_async(resource: Resource) -> None:
    """Asynchronously index a directory."""
    resource_service.update_resource_indexing_status(resource.uri, "indexing", "")
    directory_path = uri_to_path(resource.uri)
    try:
        logger.info("Loading directory content: %s", directory_path)

        documents = SimpleDirectoryReader(
            input_files=scan_directory(directory_path),
            filename_as_id=True,
            required_exts=required_exts,
        ).load_data()

        processed_documents = split_documents(documents)

        logger.info("Found %d documents", len(processed_documents))
        logger.debug("Document list: %s", [doc.doc_id for doc in processed_documents])

        # Process documents in batches
        total_documents = len(processed_documents)
        batches = [processed_documents[i : i + BATCH_SIZE] for i in range(0, total_documents, BATCH_SIZE)]
        logger.info("Splitting documents into %d batches for processing", len(batches))

        # Use thread pool for parallel batch processing
        loop = asyncio.get_event_loop()
        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            results = await loop.run_in_executor(
                executor,
                lambda: list(executor.map(process_document_batch, batches)),
            )

        # Check processing results
        if all(results):
            logger.info("Directory %s indexing completed", directory_path)
            resource_service.update_resource_indexing_status(resource.uri, "indexed", "")
        else:
            failed_batches = len([r for r in results if not r])
            error_msg = f"Some batches failed processing ({failed_batches}/{len(batches)})"
            resource_service.update_resource_indexing_status(resource.uri, "indexed", error_msg)
            logger.error(error_msg)

    except OSError as e:
        error_msg = f"Directory indexing failed: {directory_path}"
        resource_service.update_resource_indexing_status(resource.uri, "failed", error_msg)
        logger.exception(error_msg)
        raise e  # noqa: TRY201


@router.get("/api/v1/readyz")
async def readiness_probe() -> dict[str, str]:
    """Readiness probe endpoint."""
    return {"status": "ok"}


@router.post(
    "/api/v1/add_resource",
    response_model="dict[str, str]",
    summary="Add a resource for watching and indexing",
    description="""
    Adds a resource to the watch list and starts indexing all existing documents in it asynchronously.
    """,
    responses={
        200: {"description": "Resource successfully added and indexing started"},
        404: {"description": "Resource not found"},
        400: {"description": "Resource already being watched"},
    },
)
async def add_resource(request: ResourceRequest, background_tasks: BackgroundTasks):
    logger.debug("add_resource %s", request.uri)
    # Check if resource already exists
    resource = resource_service.get_resource(request.uri)
    if resource and resource.status == "active":
        return {
            "status": "success",
            "message": f"Resource {request.uri} added and indexing started in background",
        }

    resource_type = "local"

    async def background_task(resource: Resource) -> None:
        pass

    if is_local_uri(request.uri):
        directory = uri_to_path(request.uri)
        if not directory.exists():
            raise HTTPException(status_code=404, detail=f"Directory not found: {directory}")

        if not directory.is_dir():
            raise HTTPException(status_code=400, detail=f"{directory} is not a directory")

        git_directory = directory / ".git"
        if not git_directory.exists() or not git_directory.is_dir():
            raise HTTPException(status_code=400, detail=f"{git_directory} ia not a git repository")

        # Create observer
        event_handler = FileSystemHandler(directory=directory)
        observer = Observer()
        observer.schedule(event_handler, str(directory), recursive=True)
        observer.start()
        watched_resources[request.uri] = observer

        background_task = index_local_resource_async
    elif is_remote_uri(request.uri):
        if not is_remote_resource_exists(request.uri):
            raise HTTPException(status_code=404, detail="web resource not found")

        resource_type = "remote"

        background_task = index_remote_resource_async
    else:
        raise HTTPException(status_code=400, detail=f"Invalid URI: {request.uri}")

    if resource:
        if resource.name != request.name:
            raise HTTPException(
                status_code=400,
                detail=f"Resource name cannot be changed: {resource.name}",
            )

        resource_service.update_resource_status(resource.uri, "active")
    else:
        exists_resource = resource_service.get_resource_by_name(request.name)
        if exists_resource:
            raise HTTPException(status_code=400, detail="Resource with same name already exists")
        # Add to database
        resource = Resource(
            id=None,
            name=request.name,
            uri=request.uri,
            type=resource_type,
            status="active",
            indexing_status="pending",
            indexing_status_message=None,
            indexing_started_at=None,
            last_indexed_at=None,
            last_error=None,
        )
        resource_service.add_resource_to_db(resource)
        background_tasks.add_task(background_task, resource)

    return {
        "status": "success",
        "message": f"Resource {request.uri} added and indexing started in background",
    }


@router.post(
    "/api/v1/remove_resource",
    response_model="dict[str, str]",
    summary="Remove a watched resource",
    description="Stops watching and indexing the specified resource",
    responses={
        200: {"description": "Resource successfully removed from watch list"},
        404: {"description": "Resource not found in watch list"},
    },
)
async def remove_resource(request: ResourceURIRequest):
    resource = resource_service.get_resource(request.uri)
    if not resource or resource.status != "active":
        raise HTTPException(status_code=404, detail="Resource not being watched")

    if request.uri in watched_resources:
        # Stop watching
        observer = watched_resources[request.uri]
        observer.stop()
        observer.join()
        del watched_resources[request.uri]

    # Update database status
    resource_service.update_resource_status(request.uri, "inactive")

    return {"status": "success", "message": f"Resource {request.uri} removed"}


@router.post(
    "/api/v1/retrieve",
    response_model=RetrieveResponse,
    summary="Retrieve information from indexed documents",
    description="""
    Performs a semantic search over all indexed documents and returns relevant information.
    The response includes both the answer and the source documents used to generate it.
    """,
    responses={
        200: {"description": "Successfully retrieved information"},
        500: {"description": "Internal server error during retrieval"},
    },
)
async def retrieve(request: RetrieveRequest):
    if is_local_uri(request.base_uri):
        directory = uri_to_path(request.base_uri)
        # Validate directory exists
        if not directory.exists():
            raise HTTPException(status_code=404, detail=f"Directory not found: {request.base_uri}")

    logger.info(
        "Received retrieval request: %s for base uri: %s",
        request.query,
        request.base_uri,
    )

    cached_file_contents = {}

    # Create a filter function to only include documents from the specified directory
    def filter_documents(node: NodeWithScore) -> bool:
        uri = get_node_uri(node.node)
        if not uri:
            return False
        if is_path_node(node.node):
            file_path = uri_to_path(uri)
            # Check if the file path starts with the specified directory
            file_path = file_path.resolve()
            directory = uri_to_path(request.base_uri).resolve()
            # Check if directory is a parent of file_path
            try:
                file_path.relative_to(directory)
                if not file_path.exists():
                    logger.warning("File not found: %s", file_path)
                    return False
                content = cached_file_contents.get(file_path)
                if content is None:
                    with file_path.open("r", encoding="utf-8") as f:
                        content = f.read()
                        cached_file_contents[file_path] = content
                if node.node.get_content() not in content:
                    logger.warning("File content does not match: %s", file_path)
                    return False
                return True
            except ValueError:
                return False
        if uri == request.base_uri:
            return True
        base_uri = request.base_uri
        if not base_uri.endswith(os.path.sep):
            base_uri += os.path.sep
        return uri.startswith(base_uri)

    # Create a custom post processor
    class ResourceFilterPostProcessor(MetadataReplacementPostProcessor):
        """Post-processor for filtering nodes based on directory."""

        def __init__(self: ResourceFilterPostProcessor) -> None:
            """Initialize the post-processor."""
            super().__init__(target_metadata_key="filtered")

        def postprocess_nodes(
            self: ResourceFilterPostProcessor,
            nodes: list[NodeWithScore],
            query_bundle: QueryBundle | None = None,
            query_str: str | None = None,
        ) -> list[NodeWithScore]:
            """
            Filter nodes based on directory path.

            Args:
            ----
                nodes: The nodes to process
                query_bundle: Optional query bundle for the query
                query_str: Optional query string

            Returns:
            -------
                List of filtered nodes

            """
            return [node for node in nodes if filter_documents(node)]

    # Create query engine with the filter
    query_engine = index.as_query_engine(
        node_postprocessors=[ResourceFilterPostProcessor()],
    )

    logger.info("Executing retrieval query")
    response = query_engine.query(request.query)

    # If no documents were found in the specified directory
    if not response.source_nodes:
        raise HTTPException(
            status_code=404,
            detail=f"No relevant documents found in uri: {request.base_uri}",
        )

    # Process source documents, ensure readable text
    sources = []
    for node in response.source_nodes[: request.top_k]:
        try:
            content = node.node.get_content()

            uri = get_node_uri(node.node)

            # Handle byte-type content
            if isinstance(content, bytes):
                try:
                    content = content.decode("utf-8", errors="replace")
                except UnicodeDecodeError as e:
                    logger.warning(
                        "Unable to decode document content: %s, error: %s",
                        uri,
                        str(e),
                    )
                    continue

            # Validate and clean text
            if is_valid_text(str(content)):
                cleaned_content = clean_text(str(content))
                # Add document source information with file path
                doc_info = {
                    "uri": uri,
                    "content": cleaned_content,
                    "score": float(node.score) if node.score is not None else None,
                }
                sources.append(doc_info)
            else:
                logger.warning("Skipping invalid document content: %s", uri)

        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            logger.warning("Error processing source document", exc_info=True)
            continue

    logger.info("Retrieval completed, found %d relevant documents", len(sources))

    # Process response text similarly
    response_text = str(response)
    response_text = "".join(char for char in response_text if char.isprintable() or char in "\n\r\t")

    return {
        "response": response_text,
        "sources": sources,
    }


class IndexingStatusRequest(BaseModel):
    """Request model for indexing status."""

    uri: str = Field(..., description="URI of the resource to get indexing status for")


class IndexingStatusResponse(BaseModel):
    """Model for indexing status response."""

    uri: str = Field(..., description="URI of the resource being monitored")
    is_watched: bool = Field(..., description="Whether the directory is currently being watched")
    files: list[IndexingHistory] = Field(..., description="List of files and their indexing status")
    total_files: int = Field(..., description="Total number of files processed in this directory")
    status_summary: dict[str, int] = Field(
        ...,
        description="Summary of indexing statuses (count by status)",
    )


@router.post(
    "/api/v1/indexing_status",
    response_model=IndexingStatusResponse,
    summary="Get indexing status for a resource",
    description="""
    Returns the current indexing status for all files in the specified resource, including:
    * Whether the resource is being watched
    * Status of each files in the resource
    """,
    responses={
        200: {"description": "Successfully retrieved indexing status"},
        404: {"description": "Resource not found"},
    },
)
async def get_indexing_status_for_resource(request: IndexingStatusRequest):
    resource_files = []
    status_counts = {}
    if is_local_uri(request.uri):
        directory = uri_to_path(request.uri).resolve()
        if not directory.exists():
            raise HTTPException(status_code=404, detail=f"Directory not found: {directory}")

    # Get indexing history records for the specific directory
    resource_files = indexing_history_service.get_indexing_status(base_uri=request.uri)

    logger.info("Found %d files in resource %s", len(resource_files), request.uri)
    for file in resource_files:
        logger.debug("File status: %s - %s", file.uri, file.status)

    # Count files by status
    for file in resource_files:
        status_counts[file.status] = status_counts.get(file.status, 0) + 1

    return IndexingStatusResponse(
        uri=request.uri,
        is_watched=request.uri in watched_resources,
        files=resource_files,
        total_files=len(resource_files),
        status_summary=status_counts,
    )


class ResourceListResponse(BaseModel):
    """Response model for listing resources."""

    resources: list[Resource] = Field(..., description="List of all resources")
    total_count: int = Field(..., description="Total number of resources")
    status_summary: dict[str, int] = Field(
        ...,
        description="Summary of resource statuses (count by status)",
    )


@router.get(
    "/api/v1/resources",
    response_model=ResourceListResponse,
    summary="List all resources",
    description="""
    Returns a list of all resources that have been added to the system, including:
    * Resource URI
    * Resource type (path/https)
    * Current status
    * Last indexed timestamp
    * Any errors
    """,
    responses={
        200: {"description": "Successfully retrieved resource list"},
    },
)
async def list_resources() -> ResourceListResponse:
    """Get all resources and their current status."""
    # Get all resources from database
    resources = resource_service.get_all_resources()

    # Count resources by status
    status_counts = {}
    for resource in resources:
        status_counts[resource.status] = status_counts.get(resource.status, 0) + 1

    return ResourceListResponse(
        resources=resources,
        total_count=len(resources),
        status_summary=status_counts,
    )


@router.get("/api/health")
async def health_check() -> dict[str, str]:
    """Health check endpoint."""
    return {"status": "ok"}


def initialize_app(cli_settings: argparse.Namespace) -> FastAPI:
    """Initialize service state and construct the worker application."""
    global max_workers, watched_resources, file_last_modified, index_lock
    global index, embedding_splitter, max_embedding_tokens
    global base_data_dir

    base_data_dir = cli_settings.base_data_dir
    chroma_persist_dir = base_data_dir / "chroma_db"
    state_home = Path(os.environ.get("XDG_STATE_HOME", ""))
    if not state_home.is_absolute():
        state_home = Path.home() / ".local" / "state"
    log_dir = base_data_dir / "logs" if cli_settings.data_dir else state_home / "avante-rag-service" / "logs"
    db_file = base_data_dir / "sqlite" / "indexing_history.db"
    for directory in (base_data_dir, log_dir, db_file.parent, chroma_persist_dir):
        directory.mkdir(parents=True, exist_ok=True)
    configure_logging(cli_settings.log_level, log_dir)
    logger.info("data dir: %s", base_data_dir.resolve())

    max_workers = multiprocessing.cpu_count()
    watched_resources = {}
    file_last_modified = {}
    index_lock = threading.Lock()

    # Initialize database
    init_db(db_file)

    # Initialize ChromaDB and LlamaIndex services
    settings = Settings(
        allow_reset=True,
    )
    chroma_client = chromadb.PersistentClient(path=str(chroma_persist_dir), settings=settings)

    # Check if provider or model has changed
    rag_embed_provider = cli_settings.embed_provider
    rag_embed_endpoint = cli_settings.embed_endpoint
    rag_embed_model = cli_settings.embed_model
    rag_embed_api_key = cli_settings.embed_api_key
    rag_embed_extra = cli_settings.embed_extra
    rag_llm_extra = cli_settings.llm_extra
    try:
        embed_extra = json.loads(rag_embed_extra) if rag_embed_extra is not None else {}
    except json.JSONDecodeError:
        logger.error("Failed to decode --embed-extra, defaulting to empty dict.")
        embed_extra = {}

    max_embedding_tokens = parse_positive_int(
        embed_extra.pop("max_embedding_tokens", DEFAULT_MAX_EMBEDDING_TOKENS),
        DEFAULT_MAX_EMBEDDING_TOKENS,
        "embed.extra.max_embedding_tokens",
    )
    max_embedding_token_overlap = min(50, max_embedding_tokens // 5)
    embedding_splitter = SentenceSplitter(
        chunk_size=max_embedding_tokens,
        chunk_overlap=max_embedding_token_overlap,
    )
    logger.info("Embedding chunks limited to %d tokens", max_embedding_tokens)

    # Try to read previous config
    config_home = Path(os.environ.get("XDG_CONFIG_HOME", ""))
    if not config_home.is_absolute():
        config_home = Path.home() / ".config"
    config_file = config_home / "avante" / "rag_config.json"
    config_file.parent.mkdir(parents=True, exist_ok=True)
    current_config = {
        "provider": rag_embed_provider,
        "embed_model": rag_embed_model,
        "max_embedding_tokens": max_embedding_tokens,
    }
    if config_file.exists():
        logger.info("Opening config file %s", config_file)
        with Path.open(config_file, "r") as f:
            prev_config = json.load(f)
            if prev_config != current_config:
                # Clear existing data if config changed
                logger.info("Detected config change, clearing existing data...")
                chroma_client.reset()

    # Save current config
    with Path.open(config_file, "w") as f:
        json.dump(current_config, f)

    chroma_collection = chroma_client.get_or_create_collection("documents")  # pyright: ignore
    vector_store = ChromaVectorStore(chroma_collection=chroma_collection)
    storage_context = StorageContext.from_defaults(vector_store=vector_store)

    try:
        llm_extra = json.loads(rag_llm_extra) if rag_llm_extra is not None else {}
    except json.JSONDecodeError:
        logger.error("Failed to decode --llm-extra, defaulting to empty dict.")
        llm_extra = {}

    # Initialize embedding model and LLM based on provider using the factory
    try:
        logger.debug("Initializing embedding model %s at endpoint %s", rag_embed_model, rag_embed_endpoint)
        embed_model = initialize_embed_model(
            embed_provider=rag_embed_provider,
            embed_model=rag_embed_model,
            embed_endpoint=rag_embed_endpoint,
            embed_api_key=rag_embed_api_key,
            embed_extra=embed_extra,
        )
        logger.info("Embedding model initialized successfully.")
    except (ValueError, RuntimeError) as e:
        error_msg = f"Failed to initialize embedding model: {e}"
        logger.error(error_msg, exc_info=True)
        raise RuntimeError(error_msg) from e

    try:
        llm_model = initialize_llm_model(
            llm_provider=cli_settings.llm_provider,
            llm_model=cli_settings.llm_model,
            llm_endpoint=cli_settings.llm_endpoint,
            llm_api_key=cli_settings.llm_api_key,
            llm_extra=llm_extra,
        )
        logger.info("LLM model initialized successfully.")
    except (ValueError, RuntimeError) as e:
        error_msg = f"Failed to initialize LLM model: {e}"
        logger.error(error_msg, exc_info=True)
        raise RuntimeError(error_msg) from e

    li.Settings.embed_model = embed_model
    li.Settings.llm = llm_model

    try:
        index = load_index_from_storage(storage_context)
    except (OSError, ValueError) as e:
        logger.error("Failed to load index from storage %s: %s", str(chroma_persist_dir), e)
        index = VectorStoreIndex([], storage_context=storage_context)

    app = FastAPI(
        title="RAG Service API",
        description="""
        RAG (Retrieval-Augmented Generation) Service API for managing document indexing and retrieval.

        ## Features
        * Add resources for document watching and indexing
        * Remove watched resources
        * Retrieve relevant information from indexed resources
        * Monitor indexing status
        """,
        version="1.0.0",
        docs_url="/docs",
        lifespan=lifespan,
        redoc_url="/redoc",
    )
    app.include_router(router)
    return app
