"""baseline - pre-existing schema

Revision ID: a1b2c3d4e5f6
Revises:
Create Date: 2026-07-07

"""
from typing import Sequence, Union

revision: str = "a1b2c3d4e5f6"
down_revision: Union[str, Sequence[str], None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    pass


def downgrade() -> None:
    pass
