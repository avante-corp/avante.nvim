import os
from pathlib import Path


def xdg_directory(variable: str, default: Path) -> Path:
    """Resolve an XDG directory, ignoring empty or relative values."""
    value = os.environ.get(variable, "")
    path = Path(value)
    return path if path.is_absolute() else default


# Keep DATA_DIR as an override for launchers with a dedicated data volume.
data_dir = os.environ.get("DATA_DIR")
BASE_DATA_DIR = (
    Path(data_dir)
    if data_dir
    else xdg_directory("XDG_DATA_HOME", Path.home() / ".local" / "share") / "avante-rag-service"
)
DB_FILE = BASE_DATA_DIR / "sqlite" / "indexing_history.db"
