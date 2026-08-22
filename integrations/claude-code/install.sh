#!/bin/sh
# Installs the optional macon sentinel skill for Claude Code.
#
# Separate from the repository's install.sh on purpose: that one asks for a root
# password, writes to a system prefix and registers a LaunchDaemon. This one
# copies a Markdown file into the user's home directory and needs no privilege
# at all. Bundling them would mean an agent integration rode in on a root
# install, which nobody asked for.
#
# Usage: sh integrations/claude-code/install.sh [--skills-dir DIR]
set -u

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
SKILLS_DIR=${MACON_SKILLS_DIR:-$HOME/.claude/skills}
DEST_NAME=macon-sentinel

while [ $# -gt 0 ]; do
    case $1 in
        --skills-dir)
            if [ $# -lt 2 ]; then
                printf 'macon: --skills-dir needs a directory\n' >&2
                exit 1
            fi
            SKILLS_DIR=$2
            shift 2
            ;;
        -h | --help)
            printf 'usage: sh install.sh [--skills-dir DIR]\n'
            exit 0
            ;;
        *)
            printf 'macon: unknown argument: %s\n' "$1" >&2
            exit 1
            ;;
    esac
done

# Refused rather than escalated. Installing this as root would write the skill
# into root's home, where the agent that needs it will never look -- and would
# leave a root-owned directory inside a user's ~/.claude for the same reason
# macon's own installer refuses root.
if [ "$(id -u)" -eq 0 ]; then
    printf 'macon: do not run this with sudo -- it installs into your own home.\n' >&2
    exit 1
fi

if [ ! -f "$SRC_DIR/SKILL.md" ]; then
    printf 'macon: SKILL.md is missing from %s\n' "$SRC_DIR" >&2
    exit 1
fi

DEST="$SKILLS_DIR/$DEST_NAME"
if ! mkdir -p "$DEST"; then
    printf 'macon: could not create %s\n' "$DEST" >&2
    exit 1
fi

if ! cp "$SRC_DIR/SKILL.md" "$DEST/SKILL.md"; then
    printf 'macon: could not write %s/SKILL.md\n' "$DEST" >&2
    exit 1
fi

printf 'installed the macon sentinel skill into %s\n' "$DEST"
printf 'start a session with: macon on 8, and let the agent run: macon done\n'
