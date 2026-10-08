from __future__ import annotations

from pathlib import Path

import pytest

from .fixtures import make_base_audio


@pytest.fixture(scope="session")
def base_audio(tmp_path_factory: pytest.TempPathFactory) -> dict[str, Path]:
    return make_base_audio(tmp_path_factory.mktemp("base"))
