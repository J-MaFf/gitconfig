#!/bin/bash
# Shared bash utilities sourced by mac and linux gitconfig scripts.
# Source this file from a script that has already set REPO_ROOT and HOME_DIR.

# Generate ~/.gitconfig from .gitconfig.template
# Usage: generate_gitconfig REPO_ROOT HOME_DIR FORCE
generate_gitconfig() {
    local repo_root="$1"
    local home_dir="$2"
    local force="${3:-false}"
    local template_path="$repo_root/.gitconfig.template"
    local output_path="$home_dir/.gitconfig"

    echo "Git Configuration Generator"
    echo "====================================="
    echo "Repository: $repo_root"
    echo "Home Directory: $home_dir"
    echo "Template: $template_path"
    echo "Output: $output_path"
    echo ""

    if [ ! -f "$template_path" ]; then
        echo "[ERROR] Template not found: $template_path"
        return 1
    fi

    if [ -f "$output_path" ] && [ "$force" = "false" ]; then
        echo ".gitconfig already exists at: $output_path"
        read -p "Overwrite? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Cancelled."
            return 0
        fi
    fi

    if [ -f "$output_path" ]; then
        cp "$output_path" "$output_path.bak"
        echo "[INFO] Backed up existing .gitconfig to .gitconfig.bak"
    fi

    local generated_content
    generated_content=$(cat "$template_path")
    generated_content="${generated_content//\{\{REPO_PATH\}\}/$repo_root}"
    generated_content="${generated_content//\{\{HOME_DIR\}\}/$home_dir}"

    echo "$generated_content" > "$output_path"
    echo "[OK] Generated .gitconfig"
    echo ""

    if git config --file "$output_path" --list > /dev/null 2>&1; then
        echo "[OK] Git configuration verified!"
    else
        echo "[WARN] Git may have issues reading the configuration"
    fi

    echo ""
    echo "Configuration generated successfully!"
    echo "====================================="
    echo ""
    echo "Generated values:"
    echo "  Repository Path: $repo_root"
    echo "  Home Directory: $home_dir"
    echo ""
    echo "To customize, edit the template ($template_path) and re-run,"
    echo "or add overrides to ~/.gitconfig.local"
    echo ""
}

# Back up then remove a file (backs up to Existing.<name>.bak in same directory)
# Usage: backup_file TARGET_PATH
# Returns 0 if backed up, 1 if not found (skipped)
backup_file() {
    local target="$1"
    local dir
    dir="$(dirname "$target")"
    local filename
    filename="$(basename "$target")"
    local backup="$dir/Existing.$filename.bak"

    if [ -e "$target" ] || [ -L "$target" ]; then
        [ -e "$backup" ] && rm -f "$backup"
        mv "$target" "$backup"
        echo "[OK] Backed up $filename to Existing.$filename.bak"
        return 0
    else
        echo "[SKIP] $filename not found"
        return 1
    fi
}

# Create a symlink from SOURCE to LINK, backing up any existing file at LINK
# Usage: create_symlink SOURCE LINK FORCE
# Returns 0 on success or skip, 1 on error
create_symlink() {
    local source_file="$1"
    local link_path="$2"
    local force="${3:-false}"
    local file
    file="$(basename "$link_path")"

    if [ ! -f "$source_file" ]; then
        echo "[ERROR] Source not found: $source_file"
        return 1
    fi

    if [ -e "$link_path" ] || [ -L "$link_path" ]; then
        if [ "$force" = "false" ]; then
            read -p "$file exists. Overwrite? (y/n) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                echo "Skipped: $file"
                return 0
            fi
        fi
        local backup
        backup="$(dirname "$link_path")/Existing.$file.bak"
        [ -e "$backup" ] && rm -f "$backup"
        mv "$link_path" "$backup"
        echo "Backed up existing $file to Existing.$file.bak"
    fi

    if ln -s "$source_file" "$link_path" 2>/dev/null; then
        echo "[OK] Linked $file"
        return 0
    else
        echo "[FAIL] Could not create symlink for $file"
        return 1
    fi
}

# Upsert the current signing identity into an allowed_signers file so git can
# verify SSH commit signatures locally. Without it, `git log --show-signature`
# and `git verify-commit` report "No signature" even though commits are signed.
# Reads the signing key and email from git config. Idempotent: re-running does not
# duplicate the line, and entries for other identities are preserved.
# Usage: update_allowed_signers ALLOWED_SIGNERS_PATH
update_allowed_signers() {
    local allowed_signers_path="$1"
    local signing_key signer_email raw_key pub_key candidate ssh_dir line

    # `|| true` keeps `set -e` from aborting when a key is unset (git config
    # --get exits non-zero); the empty-check below handles it gracefully.
    signing_key="$(git config --get user.signingkey 2>/dev/null || true)"
    signer_email="$(git config --get user.email 2>/dev/null || true)"

    if [ -z "$signing_key" ] || [ -z "$signer_email" ]; then
        echo "[WARN] No user.signingkey/user.email configured; skipped allowed_signers"
        return 0
    fi

    # Resolve the public key: either the literal key (1Password) or a *.pub file
    # (file-based signing key path).
    case "$signing_key" in
        ssh-*|sk-ssh-*|ecdsa-*)
            raw_key="$signing_key"
            ;;
        *)
            candidate="$signing_key"
            case "$candidate" in
                *.pub) ;;
                *) candidate="$candidate.pub" ;;
            esac
            [ -f "$candidate" ] && raw_key="$(cat "$candidate")"
            ;;
    esac

    if [ -z "$raw_key" ]; then
        echo "[WARN] Could not resolve signing public key; skipped allowed_signers"
        return 0
    fi

    # Normalize to "<keytype> <base64>" — drop any trailing comment.
    pub_key="$(printf '%s' "$raw_key" | awk '{print $1" "$2}')"

    ssh_dir="$(dirname "$allowed_signers_path")"
    [ -d "$ssh_dir" ] || mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir" 2>/dev/null || true

    line="$signer_email namespaces=\"git\" $pub_key"
    if [ -f "$allowed_signers_path" ] && grep -qF -- "$line" "$allowed_signers_path"; then
        echo "[OK] allowed_signers already up to date"
    else
        printf '%s\n' "$line" >> "$allowed_signers_path"
        echo "[OK] Updated $allowed_signers_path"
    fi
}

# Set git global core.excludesfile to HOME_DIR/.gitignore_global
# Usage: configure_global_gitignore HOME_DIR
configure_global_gitignore() {
    local home_dir="$1"
    local gitignore_path="$home_dir/.gitignore_global"

    if [ -e "$gitignore_path" ]; then
        if git config --global core.excludesfile "$gitignore_path" 2>/dev/null; then
            echo "[OK] Configured global excludesfile"
        else
            echo "[FAIL] Could not configure global excludesfile"
        fi
    else
        echo "[WARN] .gitignore_global not found"
    fi
}
