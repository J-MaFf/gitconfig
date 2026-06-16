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
    "skill-sync": ("Claude Skills", "Sync the claude-skills repo (~/.claude/skills): pull --ff-only"),
    "skill-publish": ("Claude Skills", "Publish new/edited skills (~/.claude/skills) via a PR with auto-merge"),
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
            ("ctrl+right", "next_tab", "Next category"),
            ("ctrl+left", "prev_tab", "Prev category"),
            ("escape", "clear_search", "Clear search"),
            ("q", "quit", "Quit"),
        ]
        # Class-level default so handlers that may fire during mount (e.g. Tabs
        # posting TabActivated before on_mount runs) never hit an unset attribute.
        _query = ""

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
            self.query_one(Tabs).focus()
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
                f"{shown} shown  -  ctrl+left/right: categories, type to search, q: quit"
            )

        def _shift_tab(self, delta):
            tabs = self.query_one(Tabs)
            idx = (self._active_index() + delta) % len(tabs_order)
            tabs.active = f"cat-{idx}"

        def action_next_tab(self):
            self._shift_tab(1)

        def action_prev_tab(self):
            self._shift_tab(-1)

        def action_clear_search(self):
            search = self.query_one("#search", Input)
            search.value = ""
            self._query = ""
            self._refresh()

        def on_input_changed(self, event):
            if event.input.id == "search":
                self._query = event.value
                self._refresh()

        def on_tabs_tab_activated(self, event):
            self._refresh()

    return AliasBrowser()


def _launch_alias_browser(aliases):
    """Launch the interactive Textual alias browser.

    Returns True if the browser ran, False if Textual is unavailable or the UI
    could not start -- the caller then prints the static table instead.
    """
    try:
        app = _build_alias_app(aliases)
        if app is None:
            return False
        app.run()
        return True
    except Exception:
        # An incompatible terminal (or any UI error) falls back to the static
        # table rather than leaving the user with no output.
        return False


def print_aliases(force_plain=False):
    """Show git aliases.

    In an interactive terminal with Textual installed, this launches the
    categorized, searchable browser. When output is piped, in CI, when --plain
    is passed, or when Textual is unavailable, it falls back to a static grouped
    table so 'git alias | grep ...' and scripts keep working.
    """
    aliases = get_git_aliases()
    if not force_plain and sys.stdout.isatty() and _launch_alias_browser(aliases):
        return
    _print_aliases_table(aliases)


if __name__ == "__main__":
    if len(sys.argv) > 1:
        function_name = sys.argv[1]
        if function_name == "print_aliases":
            print_aliases(force_plain="--plain" in sys.argv)
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
        else:
            print(f"Function {function_name} not found.")
    else:
        print("No function name provided.")
