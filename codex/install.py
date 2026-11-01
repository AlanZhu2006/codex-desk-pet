#!/usr/bin/env python3
"""Install this fork's native Codex pet without changing app preferences."""
import argparse
import json
import os
from pathlib import Path
import shutil
from datetime import datetime, timezone


def install(source, pet_root, replace=False):
    manifest = json.loads((source / 'pet.json').read_text(encoding='utf-8'))
    sprite = source / manifest['spritesheetPath']
    if sprite.resolve().parent != source.resolve() or not sprite.is_file():
        raise ValueError('The spritesheet must be a file inside the pet package.')
    target = pet_root / source.name
    files = ('pet.json', manifest['spritesheetPath'])
    if target.exists():
        if all((target / f).is_file() and (target / f).read_bytes() == (source / f).read_bytes() for f in files):
            return target, 'Already installed'
        if not replace:
            raise FileExistsError(f'{target} already exists; use --replace to back it up and update it.')
        backup_root = pet_root.parent / 'pet-backups'
        backup_root.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
        target.rename(backup_root / f'{source.name}-{stamp}')
    pet_root.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, target)
    return target, 'Installed'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--replace', action='store_true', help='Back up an existing different package before updating it.')
    args = parser.parse_args()
    source = Path(__file__).resolve().parent / 'claude-sunflower'
    codex_home = Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))).expanduser()
    try:
        target, action = install(source, codex_home / 'pets', args.replace)
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f'{error}\n')
    print(f'{action}: {target}')
    print('In Codex, open Settings > Mini & Pets / Pets, refresh local pets, then select Claude 娘 · 向日葵.')


if __name__ == '__main__':
    main()
