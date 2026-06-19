# Dependencies: rich
# To install dependencies, run: python -m pip install rich
# To test that rich is installed, run: python -m rich
#
# This script is machine-agnostic and designed to work from any installation directory.
# It dynamically locates git configuration and operates on the current repository.

import os
import sys
import subprocess
import re
import json
import shutil

try:
    from rich.console import Console
    from rich.table import Table
    from rich.markup import escape
except ImportError:
    print("Error: the 'rich' library is not installed.")
    print("Run the install script for your platform, or: pip install rich")
    sys.exit(1)


def run_git(*args, check=False):
    return subprocess.run(
        ["git", *args],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=check,
    )


def _default_branch():
    """Return the configured default branch name, falling back to 'main'."""
    result = run_git("config", "--get", "init.defaultBranch")
    if result.returncode == 0 and result.stdout.strip():
        return result.stdout.strip()
    return "main"


def cleanup_branches(force=False):
    """Run git cleanup and display deleted branches in a table.

    Args:
        force: If True, delete both branches with deleted remotes AND local-only branches.
               If False, only delete branches where the remote has been deleted (merged branches).
    """
    console = Console()

    try:
        # Verify we're in a git repository
        try:
            run_git("rev-parse", "--git-dir", check=True)
        except subprocess.CalledProcessError:
            console.print("[red]Error: Not in a git repository[/red]")
            return

        # Get current branch
        result_current = run_git("rev-parse", "--abbrev-ref", "HEAD", check=True)
        current_branch = result_current.stdout.strip()
        switched_branch = False
        default_branch = _default_branch()

        # Switch to default branch if not already on it
        if current_branch != default_branch:
            console.print(
                f"[cyan]Switching from '{current_branch}' to '{default_branch}'...[/cyan]"
            )
            result = run_git("checkout", default_branch)
            if result.returncode != 0:
                console.print("[red]Error: Failed to switch to main branch[/red]")
                console.print(f"[red]{result.stderr.strip()}[/red]")
                return
            switched_branch = True

        # Get all branches before cleanup
        result_before = run_git("branch", "-vv", check=True)
        branches_before = set(
            line.strip().split()[0].lstrip("*").strip()
            for line in result_before.stdout.strip().split("\n")
            if line.strip()
        )

        # Run the actual cleanup command (not the alias to avoid recursion)
        console.print("[cyan]Running git cleanup...[/cyan]")
        run_git("fetch", "-p")

        # Pull latest changes on main so local doesn't fall behind after cleanup
        console.print("[cyan]Pulling latest changes on main...[/cyan]")
        pull_result = run_git("pull")
        if pull_result.returncode != 0:
            console.print(f"[yellow]Warning: git pull failed: {pull_result.stderr.strip()}[/yellow]")

        # Get list of branches to delete:
        # 1. Branches with no remote tracking (no [origin/...] in output) - requires confirmation
        # 2. Branches where the remote has been deleted (contains ": gone]") - auto-delete
        result_vv = run_git("branch", "-vv")

        # Handle empty or failed output
        if not result_vv.stdout:
            console.print("[yellow]Warning: Could not get branch information[/yellow]")
            return

        branches_to_delete = []
        for line in result_vv.stdout.strip().split("\n"):
            if not line.strip():
                continue
            # Skip the current branch (marked with *)
            if line.startswith("*"):
                continue

            # Extract branch name (first field, after stripping *)
            parts = line.strip().split()
            if not parts:
                continue
            branch_name = parts[0].lstrip("*").strip()

            # Check if branch has no remote tracking or remote is gone
            has_no_remote = "[origin/" not in line
            remote_is_gone = ": gone]" in line

            if remote_is_gone:
                # Auto-delete branches where remote has been deleted (merged branches)
                branches_to_delete.append(branch_name)
            elif has_no_remote and force:
                # Delete local-only branches (never had a remote) only with --force flag
                branches_to_delete.append(branch_name)

        # Delete the identified branches
        for branch in branches_to_delete:
            result = run_git("branch", "-D", branch)
            if result.returncode != 0:
                console.print(
                    f"[yellow]Warning: Failed to delete branch '{branch}': {result.stderr.strip()}[/yellow]"
                )

        # Get all branches after cleanup
        result_after = run_git("branch", "-vv", check=True)
        branches_after = set(
            line.strip().split()[0].lstrip("*").strip()
            for line in result_after.stdout.strip().split("\n")
            if line.strip()
        )

        # Find deleted branches
        deleted_branches = sorted(branches_before - branches_after)

        # Switch back to original branch if we switched
        if switched_branch:
            # Check if the original branch was deleted during cleanup
            if current_branch in deleted_branches:
                console.print(
                    f"[yellow]Note: Your original branch '{current_branch}' was deleted during cleanup.[/yellow]"
                )
                console.print(f"[cyan]Staying on '{default_branch}'.[/cyan]\n")
            else:
                console.print(f"[cyan]Switching back to '{current_branch}'...[/cyan]")
                result = run_git("checkout", current_branch)
                if result.returncode != 0:
                    console.print(
                        f"[yellow]Warning: Failed to switch back to '{current_branch}'[/yellow]"
                    )
                    console.print(f"[yellow]{result.stderr.strip()}[/yellow]\n")

        # Print summary of deleted branches
        if deleted_branches:
            table = Table(
                title="Deleted Branches", show_lines=True, header_style="bold green"
            )
            table.add_column("Branch Name", justify="left", style="cyan")

            for branch in deleted_branches:
                table.add_row(branch)

            console.print(table)
            console.print(
                f"[green][OK] Successfully deleted {len(deleted_branches)} branch(es)[/green]\n"
            )
        else:
            console.print(
                "[dim]No branches were deleted. All local branches are up to date.[/dim]\n"
            )

    except subprocess.CalledProcessError as e:
        console.print(f"[red]Error running git cleanup: {e}[/red]")


# Category ordering for the alias table and the interactive browser's tabs.
# Aliases without an ALIAS_METADATA entry fall into "Other".
CATEGORY_ORDER = ["Inspect", "Commit", "Branch & Sync", "GitHub", "Maintenance", "Claude Skills", "Other"]

# name -> (category, description). Drives both the static grouped table and the
# interactive browser. Keep each name and its description on a single source
# line; the Pester suite greps this source for substrings such as
# "alias.*List all git aliases".
ALIAS_METADATA = {
    # Inspect
    "alias": ("Inspect", "List all git aliases in a categorized, searchable table"),
    "s": ("Inspect", "Short, branch-aware working-tree status"),
    "lg": ("Inspect", "Pretty, decorated commit graph across all branches"),
    "last": ("Inspect", "Show the most recent commit with its diffstat"),
    "recent": ("Inspect", "List local branches ordered by most recent commit"),
    "find": ("Inspect", "Find commits that added or removed a string (git find <string>)"),
    # Commit
    "amend": ("Commit", "Fold staged changes into the last commit, keeping its message"),
    "reword": ("Commit", "Edit the last commit's message"),
    "undo": ("Commit", "Undo the last commit but keep its changes staged"),
    "unstage": ("Commit", "Unstage files while keeping working-tree changes"),
    "wip": ("Commit", "Park all current work as a WIP commit (skips hooks)"),
    # Branch & Sync
    "branches": ("Branch & Sync", "Download all remote branches and create local tracking branches"),
    "cleanup": ("Branch & Sync", "Delete branches with deleted remotes (merged). Use --force for local-only too"),
    "main": ("Branch & Sync", "Switch to main (fetch, pull, cleanup). Use --all/-a for every repo in subdirectories"),
    "nb": ("Branch & Sync", "Create and switch to a new branch (git nb <name>)"),
    "pushf": ("Branch & Sync", "Force-push the current branch safely (--force-with-lease)"),
    "sync": ("Branch & Sync", "Update the current branch with rebase and autostash"),
    "start": ("Branch & Sync", "Start a GitHub issue: make a conventionally named branch from its title"),
    # GitHub
    "pr": ("GitHub", "Open the current branch's pull request in the browser"),
    "prs": ("GitHub", "Show the status of your pull requests"),
    # Maintenance
    "localconfig": ("Maintenance", "Edit machine-specific git config (~/.gitconfig.local)"),
    "selfupdate": ("Maintenance", "Pull this repo and reinstall ~/.gitconfig from the template"),
    # Claude Skills
    "skill": ("Claude Skills", "Manage ~/.claude/skills via subcommands: list, sync, status, publish (git skill <subcommand>)"),
}


def get_git_aliases():
    """Fetch configured git aliases as (name, description, category) tuples.

    Known aliases use the curated description and category from ALIAS_METADATA;
    anything else is shown with a preview of its command under "Other". The
    result is sorted by category (per CATEGORY_ORDER) then by alias name.
    """
    # Exposed under this name because the Pester suite greps for it.
    alias_descriptions = ALIAS_METADATA

    try:
        result = run_git("config", "--get-regexp", "alias", check=True)
    except subprocess.CalledProcessError:
        return []

    aliases = []
    for line in result.stdout.strip().split("\n"):
        if not line:
            continue
        # Parse "alias.name value" format
        match = re.match(r"alias\.(.+?)\s+(.+)", line)
        if not match:
            continue
        alias_name = match.group(1)
        alias_value = match.group(2)

        if alias_name in alias_descriptions:
            category, description = alias_descriptions[alias_name]
        elif alias_value.startswith("!"):
            # Shell command: show a cleaned-up, truncated preview
            command = alias_value[1:]
            description = (
                f"Shell: {command[:77]}..." if len(command) > 80 else f"Shell: {command}"
            )
            category = "Other"
        else:
            # Git sub-command: show as-is, truncated if long
            description = (
                alias_value[:77] + "..." if len(alias_value) > 80 else alias_value
            )
            category = "Other"

        aliases.append((alias_name, description, category))

    order = {cat: i for i, cat in enumerate(CATEGORY_ORDER)}
    aliases.sort(key=lambda a: (order.get(a[2], len(order)), a[0]))
    return aliases


def _read_skill_description(skill_md_path):
    """Return the one-line 'description' from a SKILL.md YAML frontmatter block.

    Handles both a single-line 'description: text' and a folded/literal block
    scalar ('description: >' or '|' followed by indented lines). Returns '' when
    there is no frontmatter or no description. Whitespace is collapsed to single
    spaces and any surrounding quotes are stripped.
    """
    try:
        with open(skill_md_path, encoding="utf-8", errors="replace") as handle:
            lines = handle.read().splitlines()
    except OSError:
        return ""

    if not lines or lines[0].strip() != "---":
        return ""

    # Collect the frontmatter lines up to the closing '---'.
    front = []
    for line in lines[1:]:
        if line.strip() == "---":
            break
        front.append(line)

    for i, line in enumerate(front):
        match = re.match(r"\s*description\s*:\s*(.*)$", line)
        if not match:
            continue
        value = match.group(1).strip()
        # Block scalar (empty value or a '>'/'|' indicator): gather the following
        # blank or more-indented lines until the next top-level key.
        if value in ("", ">", "|", ">-", "|-", ">+", "|+"):
            collected = []
            for cont in front[i + 1:]:
                if cont.strip() == "":
                    continue
                if re.match(r"\s", cont):
                    collected.append(cont.strip())
                else:
                    break
            value = " ".join(collected)
        value = value.strip()
        if len(value) >= 2 and value[0] in "\"'" and value[-1] == value[0]:
            value = value[1:-1]
        return re.sub(r"\s+", " ", value).strip()

    return ""


def _skill_last_updated(skills_dir, name, skill_md_path):
    """Return the date a skill was last updated as 'YYYY-MM-DD'.

    Prefers the last commit that touched the skill directory (when the skills
    directory is a git repo); falls back to the SKILL.md modification time, or
    'unknown' if neither is available.
    """
    result = run_git("-C", skills_dir, "log", "-1", "--format=%cs", "--", name)
    if result.returncode == 0 and result.stdout.strip():
        return result.stdout.strip()
    try:
        import datetime

        return datetime.date.fromtimestamp(os.path.getmtime(skill_md_path)).isoformat()
    except OSError:
        return "unknown"


def list_skills():
    """Print installed Claude skills (~/.claude/skills) as a rich table.

    A skill is an immediate subdirectory containing a SKILL.md. Each row shows
    the skill name, a one-line description from the SKILL.md frontmatter, and the
    date it was last updated (last commit touching it, else the file mtime).
    """
    console = Console()
    skills_dir = os.path.join(os.path.expanduser("~"), ".claude", "skills")
    if not os.path.isdir(skills_dir):
        console.print(f"[red]Skills directory not found: {skills_dir}[/red]")
        return 1

    rows = []
    for name in sorted(os.listdir(skills_dir)):
        skill_md = os.path.join(skills_dir, name, "SKILL.md")
        if not os.path.isfile(skill_md):
            continue
        description = _read_skill_description(skill_md)
        if len(description) > 100:
            description = description[:99].rstrip() + "..."
        updated = _skill_last_updated(skills_dir, name, skill_md)
        rows.append((name, description, updated))

    if not rows:
        console.print(f"[yellow]No skills found in {skills_dir}[/yellow]")
        return 0

    table = Table(title="Claude Skills", show_lines=True, header_style="bold yellow")
    table.add_column("Skill", justify="left", style="cyan", no_wrap=True)
    table.add_column("Description", justify="left", style="white")
    table.add_column("Updated", justify="left", style="green", no_wrap=True)
    for name, description, updated in rows:
        table.add_row(
            name, escape(description) if description else "(no description)", updated
        )

    console.print(table)
    console.print(f"\n[dim]{len(rows)} skills in {skills_dir}[/dim]")
    return 0


# Subcommands that delegate to the per-OS wrapper scripts shipped in the
# claude-skills repo (~/.claude/skills/scripts). Maps subcommand -> script base
# name (the .ps1 and .sh share the base). Keeping these wrappers in that repo is
# intentional so tweaks sync without touching this helper.
SKILL_SCRIPTS = {
    "sync": "skill-sync",
    "status": "skill-sync-status",
    "publish": "publish-skill",
}

# usage banner for `git skill` with no argument and `git skill help`.
SKILL_USAGE = (
    "usage: git skill <subcommand>\n"
    "\n"
    "  list      List installed skills (name, description, last updated)\n"
    "  sync      Pull ~/.claude/skills (--ff-only); never publishes local work\n"
    "  status    Show this machine's ~/.claude/skills sync state\n"
    "  publish   Publish new/edited skills via a PR (auto-merge)"
)


def _run_skill_script(base):
    """Run a claude-skills wrapper script (~/.claude/skills/scripts/<base>.{ps1,sh}).

    Picks the per-OS variant: PowerShell on Windows, bash elsewhere. Returns the
    script's exit code, or 1 if the expected script file is missing.
    """
    scripts_dir = os.path.join(os.path.expanduser("~"), ".claude", "skills", "scripts")
    if sys.platform == "win32":
        script = os.path.join(scripts_dir, base + ".ps1")
        cmd = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script]
    else:
        script = os.path.join(scripts_dir, base + ".sh")
        cmd = ["bash", script]
    if not os.path.isfile(script):
        Console(stderr=True).print(
            f"[red]git skill: wrapper script not found: {script}[/red]"
        )
        return 1
    return subprocess.run(cmd).returncode


def skill(args):
    """Dispatch a `git skill <subcommand>` invocation.

    Subcommands:
      list      List installed skills in ~/.claude/skills (name, description,
                last-updated date) as a table.
      sync      Pull ~/.claude/skills (--ff-only); flags unpublished local
                work but never publishes it (publish with `publish`).
      status    Show this machine's ~/.claude/skills sync state.
      publish   Publish new/edited skills via a PR with auto-merge.

    `list` is handled here in Python; sync/status/publish delegate to the per-OS
    wrapper scripts shipped in the claude-skills repo (see SKILL_SCRIPTS).
    """
    sub = args[0] if args else ""
    if sub == "list":
        return list_skills()
    if sub in SKILL_SCRIPTS:
        return _run_skill_script(SKILL_SCRIPTS[sub])
    if sub in ("", "help", "-h", "--help"):
        Console().print(SKILL_USAGE)
        return 0
    Console(stderr=True).print(
        f"[red]git skill: unknown subcommand '{sub}' "
        f"(try: list, sync, status, publish)[/red]"
    )
    return 1


# Issue labels -> branch-name prefix, per the git-policies branch conventions.
LABEL_PREFIX = {
    "bug": "fix",
    "documentation": "docs",
    "docs": "docs",
    "enhancement": "feat",
    "feature": "feat",
}


def _have(cmd):
    """Return True if an executable is on PATH."""
    return shutil.which(cmd) is not None


def _slugify(text, max_length=50):
    """Turn an issue title into a kebab-case branch slug."""
    slug = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    if len(slug) > max_length:
        slug = slug[:max_length].rstrip("-")
    return slug or "issue"


def start_branch(issue):
    """Create a conventionally named branch for a GitHub issue.

    Reads the issue's title and labels via the GitHub CLI, derives a branch name
    (fix/, feat/, or docs/ prefix + slugified title), and creates it from the
    up-to-date default branch. Switches to it on success.
    """
    console = Console()

    number = str(issue).lstrip("#") if issue is not None else ""
    if not number.isdigit():
        console.print("[red]Usage: git start <issue-number>[/red]")
        return 1

    if not _have("gh"):
        console.print("[red]Error: the GitHub CLI ('gh') is required for git start[/red]")
        return 1

    if run_git("rev-parse", "--git-dir").returncode != 0:
        console.print("[red]Error: Not in a git repository[/red]")
        return 1

    view = subprocess.run(
        ["gh", "issue", "view", number, "--json", "title,labels"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if view.returncode != 0:
        console.print(f"[red]Error: could not load issue #{number}[/red]")
        console.print(f"[red]{view.stderr.strip()}[/red]")
        return 1

    try:
        data = json.loads(view.stdout)
    except json.JSONDecodeError:
        console.print(f"[red]Error: unexpected response for issue #{number}[/red]")
        return 1

    title = (data.get("title") or "").strip()
    labels = [str(label.get("name", "")).lower() for label in data.get("labels", [])]
    prefix = next((LABEL_PREFIX[label] for label in labels if label in LABEL_PREFIX), "feat")
    branch = f"{prefix}/{_slugify(title)}"

    console.print(f"[cyan]Issue #{number}:[/cyan] {title or '(no title)'}")

    # Base the new branch on an up-to-date default branch when we can reach it.
    default_branch = _default_branch()
    console.print("[cyan]Fetching origin...[/cyan]")
    run_git("fetch", "origin")
    base = f"origin/{default_branch}"
    if run_git("rev-parse", "--verify", "--quiet", base).returncode != 0:
        base = "HEAD"

    if run_git("rev-parse", "--verify", "--quiet", branch).returncode == 0:
        console.print(f"[yellow]Branch '{branch}' already exists; switching to it.[/yellow]")
        switch = run_git("switch", branch)
    else:
        console.print(f"[green]Creating branch[/green] [bold]{branch}[/bold] [green]from {base}[/green]")
        switch = run_git("switch", "-c", branch, base)

    if switch.returncode != 0:
        console.print("[red]Error: failed to create or switch to the branch[/red]")
        console.print(f"[red]{switch.stderr.strip()}[/red]")
        return 1

    console.print(
        f"[green]OK On {branch}.[/green] "
        f"[dim]Commit your work, then: gh pr create --assignee J-MaFf --body \"Fixes #{number}\"[/dim]"
    )
    return 0


def switch_to_main():
    """Switch to main branch with full error handling and conflict detection.

    Steps:
    1. Verify we're in a git repository
    2. Fetch updates from remote
    3. Check for uncommitted changes
    4. Switch to main branch
    5. Pull latest changes
    6. Clean up branches with deleted remotes
    7. Detect and report merge conflicts
    """
    console = Console()

    try:
        # Step 1: Verify git repository
        result = run_git("rev-parse", "--git-dir")
        if result.returncode != 0:
            console.print("[red]Error: Not in a git repository[/red]")
            return 1

        # Get current branch
        result_current = run_git("rev-parse", "--abbrev-ref", "HEAD", check=True)
        current_branch = result_current.stdout.strip()
        default_branch = _default_branch()

        # Step 2: Fetch updates
        console.print("[cyan]Fetching updates from remote...[/cyan]")
        result = run_git("fetch", "-p")
        if result.returncode != 0:
            console.print("[red]Error: Failed to fetch from remote[/red]")
            console.print(f"[red]{result.stderr.strip()}[/red]")
            return 1
        console.print("[green]OK Fetch complete[/green]")

        # Step 3: Check for uncommitted changes
        result_status = run_git("status", "--porcelain", check=True)
        if result_status.stdout.strip():
            console.print("[red]Error: Uncommitted changes detected[/red]")
            console.print(
                f"[yellow]Please commit or stash your changes before switching to {default_branch}:[/yellow]"
            )
            console.print(result_status.stdout)
            return 1

        # Step 4: Switch to default branch (if not already there)
        if current_branch != default_branch:
            console.print(
                f"[cyan]Switching from '{current_branch}' to '{default_branch}'...[/cyan]"
            )
            result = run_git("checkout", default_branch)
            if result.returncode != 0:
                console.print(f"[red]Error: Failed to checkout {default_branch} branch[/red]")
                console.print(f"[red]{result.stderr.strip()}[/red]")
                return 1
            console.print(f"[green]OK Switched to {default_branch}[/green]")
        else:
            console.print(f"[cyan]Already on {default_branch} branch[/cyan]")

        # Step 5: Pull latest changes
        console.print("[cyan]Pulling latest changes...[/cyan]")
        result = run_git("pull")

        if result.returncode != 0:
            # Check if it's a merge conflict
            result_status = run_git("status", "--porcelain", check=True)

            if (
                "UU" in result_status.stdout
                or "AA" in result_status.stdout
                or "DD" in result_status.stdout
            ):
                console.print("[red]Error: Merge conflict detected during pull![/red]")
                console.print("[yellow]Resolve conflicts and commit:[/yellow]")
                console.print(result_status.stdout)
                console.print(
                    "[cyan]After resolving, run: git add . && git commit[/cyan]"
                )
                return 1
            else:
                console.print("[red]Error: Pull failed[/red]")
                console.print(f"[red]{result.stderr.strip()}[/red]")
                return 1

        # Step 6: Clean up branches with deleted remotes
        console.print("[cyan]Cleaning up branches with deleted remotes...[/cyan]")
        cleanup_branches(force=False)

        console.print("[green]OK Successfully switched to main and updated![/green]")
        return 0

    except subprocess.CalledProcessError as e:
        console.print(f"[red]Error: {e}[/red]")
        return 1


def _dirty_triage_lines(default_branch):
    """Build a triage summary for the current repo's dirty working tree.

    Assumes the caller has already fetched, so origin/<default_branch> is current.
    Returns formatted lines describing the current branch's position relative to
    origin/<default_branch>, its last-commit age, and a breakdown of working-tree
    changes -- enough for the user to judge stale-vs-active without the tool
    guessing intent.
    """
    branch_result = run_git("rev-parse", "--abbrev-ref", "HEAD")
    branch = branch_result.stdout.strip() or "(detached HEAD)"

    # Working-tree breakdown: untracked files start with '??', everything else
    # is a tracked modification (staged or unstaged).
    status_result = run_git("status", "--porcelain")
    modified = untracked = 0
    for line in status_result.stdout.splitlines():
        if not line.strip():
            continue
        if line.startswith("??"):
            untracked += 1
        else:
            modified += 1

    # Ahead/behind relative to origin/<default_branch>. `rev-list --left-right
    # --count A...B` prints "<left>\t<right>" = behind, ahead for A=origin, B=HEAD.
    ref = f"origin/{default_branch}"
    position = f"position vs {ref} unknown"
    rev = run_git("rev-list", "--left-right", "--count", f"{ref}...HEAD")
    if rev.returncode == 0 and rev.stdout.strip():
        try:
            behind, ahead = (int(n) for n in rev.stdout.split())
            position = f"ahead {ahead} / behind {behind} of {ref}"
        except ValueError:
            pass

    age_result = run_git("log", "-1", "--format=%cr")
    last_commit = age_result.stdout.strip() if age_result.returncode == 0 and age_result.stdout.strip() else "unknown"

    return [
        f"   [cyan]branch:[/cyan] {branch}  ({position}, last commit {last_commit})",
        f"   [cyan]working tree:[/cyan] {modified} modified, {untracked} untracked",
    ]


def update_all_main():
    """Run the switch-to-main flow for every git repo in immediate subdirectories.

    Scans the direct child directories of the current working directory. For each
    git repo that is clean, runs switch_to_main() (fetch, switch to main, pull,
    branch cleanup). Repos with a dirty working tree are NOT switched -- instead a
    triage report (branch position vs origin/main, last-commit age, working-tree
    breakdown) is printed so the user can judge stale-vs-active themselves. The
    working tree is never mutated.

    Prints a per-repo header and a final summary table classifying each repo as
    OK, Skipped (dirty), or Failed. Returns 0 if no repo failed (skips don't
    count as failures), 1 if any repo failed or none were found.
    """
    console = Console()

    original_cwd = os.getcwd()

    # Collect immediate subdirectories that are git repositories (a .git entry
    # may be a directory or a file, the latter for worktrees/submodules).
    repos = []
    for entry in sorted(os.scandir("."), key=lambda e: e.name):
        if entry.is_dir() and os.path.exists(os.path.join(entry.path, ".git")):
            repos.append(entry.name)

    if not repos:
        console.print(
            "[yellow]No git repositories found in immediate subdirectories.[/yellow]"
        )
        return 1

    results = []  # (repo_name, outcome) where outcome in {"ok", "skipped", "failed"}
    for repo in repos:
        console.print(f"\n[bold]-- {repo} --[/bold]")
        try:
            os.chdir(repo)
            # Detect a dirty working tree up front (no fetch needed for status).
            # If dirty, skip the switch and print a triage report instead of
            # touching the working tree; otherwise hand off to switch_to_main.
            status_result = run_git("status", "--porcelain")
            if status_result.returncode == 0 and status_result.stdout.strip():
                console.print("[yellow]SKIPPED: uncommitted changes[/yellow]")
                # Fetch so the ahead/behind report reflects the current remote.
                run_git("fetch", "-p")
                for line in _dirty_triage_lines(_default_branch()):
                    console.print(line)
                outcome = "skipped"
            else:
                outcome = "ok" if switch_to_main() == 0 else "failed"
        except Exception as e:
            # Don't let one repo abort the whole sweep
            console.print(f"[red]Error updating '{repo}': {e}[/red]")
            outcome = "failed"
        finally:
            os.chdir(original_cwd)
        results.append((repo, outcome))

    # Summary table
    table = Table(
        title="Update Summary", show_lines=True, header_style="bold yellow"
    )
    table.add_column("Repository", justify="left", style="cyan")
    table.add_column("Result", justify="left")

    status_label = {
        "ok": "[green]OK[/green]",
        "skipped": "[yellow]Skipped (dirty)[/yellow]",
        "failed": "[red]Failed[/red]",
    }
    for repo, outcome in results:
        table.add_row(repo, status_label[outcome])

    ok_count = sum(1 for _, o in results if o == "ok")
    skipped_count = sum(1 for _, o in results if o == "skipped")
    failed_count = sum(1 for _, o in results if o == "failed")
    console.print()
    console.print(table)
    console.print(
        f"\n[dim]Updated {ok_count}, skipped {skipped_count}, failed {failed_count} "
        f"of {len(results)} repositories[/dim]"
    )

    return 0 if failed_count == 0 else 1


def _print_aliases_table(aliases):
    """Render the static, category-grouped alias table (non-interactive fallback)."""
    console = Console()
    table = Table(title="Git Aliases", show_lines=True, header_style="bold yellow")
    table.add_column("Category", justify="left", style="green", no_wrap=True)
    table.add_column("Alias", justify="left", style="cyan", no_wrap=True)
    table.add_column("Command/Description", justify="left", style="magenta")

    last_category = None
    for name, description, category in aliases:
        if last_category is not None and category != last_category:
            table.add_section()
        # Label the category only on the first row of each group to reduce noise.
        table.add_row(category if category != last_category else "", name, description)
        last_category = category

    console.print(table)
    console.print(
        f"\n[dim]Found {len(aliases)} git aliases  -  "
        f"run 'git alias' in a terminal for the interactive browser[/dim]"
    )


def _build_alias_app(aliases):
    """Build the interactive Textual alias-browser App.

    Returns an App instance, or None if Textual is not installed. Kept separate
    from _launch_alias_browser so the UI can be exercised headlessly in tests
    (via App.run_test()).
    """
    try:
        from textual.app import App
        from textual.widgets import DataTable, Footer, Header, Input, Tab, Tabs
    except ImportError:
        return None

    # Group aliases by category, preserving CATEGORY_ORDER and dropping empties.
    grouped = {}
    for name, description, category in aliases:
        grouped.setdefault(category, []).append((name, description))
    present = [c for c in CATEGORY_ORDER if c in grouped]
    tabs_order = ["All"] + present  # "All" is the first (default) tab

    class AliasBrowser(App):
        CSS = """
        Input { margin: 1 1 0 1; }
        DataTable { height: 1fr; margin: 0 1; }
        """
        BINDINGS = [
            ("enter", "select", "Insert at prompt"),
            ("up", "cursor_up", "Up"),
            ("down", "cursor_down", "Down"),
            ("ctrl+right", "next_tab", "Next category"),
            ("ctrl+left", "prev_tab", "Prev category"),
            ("escape", "clear_or_quit", "Clear / quit"),
        ]
        # Class-level defaults so handlers that may fire during mount (e.g. Tabs
        # posting TabActivated before on_mount runs) never hit an unset attribute.
        _query = ""
        _done = False

        def compose(self):
            yield Header()
            yield Input(
                placeholder="Search aliases by name or description...", id="search"
            )
            yield Tabs(
                *[Tab(name, id=f"cat-{i}") for i, name in enumerate(tabs_order)],
                id="tabs",
            )
            yield DataTable(id="table", zebra_stripes=True)
            yield Footer()

        def on_mount(self):
            self.title = "Git Aliases"
            self._query = ""
            table = self.query_one("#table", DataTable)
            table.cursor_type = "row"
            table.add_columns("Alias", "Category", "Description")
            # Focus the search box so typing filters immediately; up/down still
            # move the table's row cursor via the app-level bindings below.
            self.query_one("#search", Input).focus()
            self._refresh()

        def _active_index(self):
            active = self.query_one(Tabs).active
            if active and active.startswith("cat-"):
                try:
                    return int(active.split("-")[1])
                except ValueError:
                    pass
            return 0

        def _refresh(self):
            table = self.query_one("#table", DataTable)
            # Columns are added in on_mount; if a tab/input event arrives first
            # (mount-order race), there is nothing to populate yet -- skip.
            if not table.columns:
                return
            table.clear()
            idx = self._active_index()
            selected = tabs_order[idx] if idx < len(tabs_order) else "All"
            needle = self._query.lower()
            shown = 0
            for category in present:
                if selected != "All" and category != selected:
                    continue
                for name, description in grouped.get(category, []):
                    if (
                        needle
                        and needle not in name.lower()
                        and needle not in description.lower()
                    ):
                        continue
                    table.add_row(name, category, description)
                    shown += 1
            self.sub_title = (
                f"{shown} shown  -  type: search  up/down: move  enter: insert  "
                f"ctrl+left/right: category  esc: clear/quit"
            )

        def _shift_tab(self, delta):
            tabs = self.query_one(Tabs)
            idx = (self._active_index() + delta) % len(tabs_order)
            tabs.active = f"cat-{idx}"

        def action_next_tab(self):
            self._shift_tab(1)

        def action_prev_tab(self):
            self._shift_tab(-1)

        def action_cursor_down(self):
            self.query_one("#table", DataTable).action_cursor_down()

        def action_cursor_up(self):
            self.query_one("#table", DataTable).action_cursor_up()

        def action_clear_or_quit(self):
            # Esc clears an active search; on an empty search it exits (no pick).
            search = self.query_one("#search", Input)
            if search.value:
                search.value = ""
                self._query = ""
                self._refresh()
            else:
                self.exit(None)

        def _selected_command(self):
            table = self.query_one("#table", DataTable)
            if table.row_count == 0:
                return None
            try:
                row = table.get_row_at(table.cursor_row)
            except Exception:
                return None
            # Row is [alias, category, description]; emit a runnable command.
            return f"git {row[0]}" if row else None

        def action_select(self):
            self._choose()

        def _choose(self):
            if self._done:
                return
            command = self._selected_command()
            if command:
                self._done = True
                self.exit(command)

        def on_input_changed(self, event):
            if event.input.id == "search":
                self._query = event.value
                self._refresh()

        def on_input_submitted(self, event):
            # Enter while the search box has focus selects the highlighted row.
            self._choose()

        def on_data_table_row_selected(self, event):
            # Enter on the focused table, or a mouse click on a row.
            self._choose()

        def on_tabs_tab_activated(self, event):
            self._refresh()

    return AliasBrowser()


def _copy_to_clipboard(text):
    """Copy text to the system clipboard.

    Returns True on success, False if no clipboard tool is available or the copy
    failed. Tries the native tool per platform: pbcopy (macOS), clip (Windows),
    and wl-copy / xclip / xsel (Linux/Wayland/X11).
    """
    if sys.platform == "darwin":
        candidates = [["pbcopy"]]
    elif os.name == "nt":
        candidates = [["clip"]]
    else:
        candidates = [
            ["wl-copy"],
            ["xclip", "-selection", "clipboard"],
            ["xsel", "--clipboard", "--input"],
        ]
    for cmd in candidates:
        if not _have(cmd[0]):
            continue
        try:
            result = subprocess.run(cmd, input=text, text=True, capture_output=True)
            if result.returncode == 0:
                return True
        except OSError:
            continue
    return False


def _run_app_on_tty(app):
    """Run a Textual app, drawing it on the controlling terminal.

    Textual renders to stderr; if the alias's stderr was not wired to the
    terminal the UI would be misrouted. When stderr is not a TTY (and we're not
    on Windows), route stdin/stdout/stderr through /dev/tty for the duration of
    the run -- the same trick as the Ctrl-G widget's `</dev/tty >/dev/tty
    2>/dev/tty` -- then restore the original descriptors. Returns app.run()'s
    value (the chosen command, or None).
    """
    saved = tty_fd = None
    if os.name != "nt" and not sys.stderr.isatty():
        try:
            tty_fd = os.open("/dev/tty", os.O_RDWR)
        except OSError:
            tty_fd = None
    try:
        if tty_fd is not None:
            saved = (os.dup(0), os.dup(1), os.dup(2))
            for target in (0, 1, 2):
                os.dup2(tty_fd, target)
        return app.run()
    finally:
        if saved is not None:
            for src, target in zip(saved, (0, 1, 2)):
                os.dup2(src, target)
            for fd in saved:
                os.close(fd)
        if tty_fd is not None:
            os.close(tty_fd)


def _launch_alias_browser(aliases, select_out=None):
    """Launch the interactive Textual alias browser.

    Returns (ran, reason): (True, None) if the browser ran; (False, reason) if it
    could not, where reason is a short human-readable explanation the caller can
    surface before falling back to the static table.

    On selection the app returns the chosen command (e.g. "git pr"). When
    select_out is a path, that command is written there (for the Ctrl-G shell
    keybinding to insert at the prompt). Otherwise -- i.e. when the browser was
    launched by typing `git alias` -- the subprocess can't reach the prompt, so
    the command is copied to the clipboard (with a printed fallback).
    """
    app = _build_alias_app(aliases)
    if app is None:
        return False, (
            f"the 'textual' package is not installed for {sys.executable} "
            f"(install it with 'pip install textual')"
        )
    try:
        choice = _run_app_on_tty(app)
    except Exception as exc:
        return False, f"the interactive browser failed ({type(exc).__name__}: {exc})"

    if choice:
        if select_out:
            try:
                with open(select_out, "w", encoding="utf-8") as handle:
                    handle.write(choice)
            except OSError:
                pass
        else:
            console = Console()
            if _copy_to_clipboard(choice):
                console.print(
                    f"[green]Copied to clipboard:[/green] [bold]{choice}[/bold]  "
                    f"[dim](paste with Cmd/Ctrl-V; Ctrl-G inserts at the prompt)[/dim]"
                )
            else:
                console.print(
                    f"[cyan]{choice}[/cyan]  "
                    f"[dim](copy it, or use Ctrl-G to insert at the prompt)[/dim]"
                )
    return True, None


def _note_browser_fallback(reason):
    """Explain (once, on stderr) why the interactive browser was skipped.

    Printed only when stderr is a TTY, so piping and CI stay clean. The note
    always points at 'git alias --plain' to silence it.
    """
    if reason and sys.stderr.isatty():
        Console(stderr=True).print(
            f"[dim]git alias: {reason}. Showing the static list "
            f"('git alias --plain' to silence this).[/dim]"
        )


def print_aliases(force_plain=False, select_out=None):
    """Show git aliases.

    In an interactive terminal with Textual installed, this launches the
    categorized, searchable browser; selecting an alias (Enter/click) yields
    "git <alias>", written to select_out (for the Ctrl-G keybinding) or copied
    to the clipboard when launched by typing `git alias`.
    When output is piped, in CI, with --plain, or without Textual it falls back
    to a static grouped table so 'git alias | grep ...' and scripts keep working
    -- except in selection mode (select_out set), where it stays silent so the
    keybinding inserts nothing. When the browser is skipped for an unexpected
    reason, a one-line explanation is printed to stderr (if stderr is a TTY).
    """
    aliases = get_git_aliases()

    if force_plain:
        if select_out is None:
            _print_aliases_table(aliases)
        return

    if sys.stdout.isatty():
        ran, reason = _launch_alias_browser(aliases, select_out=select_out)
        if ran:
            return
        # The browser couldn't start (no Textual, a UI error, ...): say why,
        # then fall through to the static table. Stay silent for Ctrl-G.
        if select_out is None:
            _note_browser_fallback(reason)
    elif select_out is None:
        # stdout is redirected/piped: the static table is the right output, but
        # explain it for someone who expected the browser at a real terminal.
        _note_browser_fallback(
            "stdout is not a TTY (piped or redirected), so the browser was "
            "skipped (use Ctrl-G for the interactive browser)"
        )

    if select_out is None:
        _print_aliases_table(aliases)


if __name__ == "__main__":
    if len(sys.argv) > 1:
        function_name = sys.argv[1]
        if function_name == "print_aliases":
            select_out = None
            if "--out" in sys.argv:
                idx = sys.argv.index("--out")
                if idx + 1 < len(sys.argv):
                    select_out = sys.argv[idx + 1]
            print_aliases(force_plain="--plain" in sys.argv, select_out=select_out)
        elif function_name == "start":
            issue_arg = sys.argv[2] if len(sys.argv) > 2 else None
            sys.exit(start_branch(issue_arg))
        elif function_name == "cleanup":
            # Check for --force flag
            force = "--force" in sys.argv or "-f" in sys.argv
            cleanup_branches(force=force)
        elif function_name == "switch_to_main":
            # `git main --all` / `-a` updates every repo in immediate subdirectories
            if "--all" in sys.argv or "-a" in sys.argv:
                sys.exit(update_all_main())
            sys.exit(switch_to_main())
        elif function_name == "update_all_main":
            sys.exit(update_all_main())
        elif function_name == "skill":
            sys.exit(skill(sys.argv[2:]))
        else:
            print(f"Function {function_name} not found.")
    else:
        print("No function name provided.")
