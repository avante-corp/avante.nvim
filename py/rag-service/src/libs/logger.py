import logging
from datetime import datetime
from pathlib import Path

logger = logging.getLogger(__name__)


def configure_logging(level: str, log_dir: Path) -> None:
    """Configure logging after the service's data directories exist."""
    logging.basicConfig(
        level=level,
        format="%(asctime)s - %(levelname)s - %(message)s",
        handlers=[
            logging.FileHandler(
                log_dir / f"rag_service_{datetime.now().astimezone().strftime('%Y%m%d')}.log",
            ),
            logging.StreamHandler(),
        ],
    )
    logging.getLogger().setLevel(level)
    logger.setLevel(level)
