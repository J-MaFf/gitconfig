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
                f"[green]✓ Successfully deleted {len(deleted_branches)} branch(es)[/green]\n"
            )
        else:
            console.print(
                "[dim]No branches were deleted. All local branches are up to date.[/dim]\n"
            )

    except subprocess.CalledProcessError as e:
        console.print(f"[red]Error running git cleanup: {e}[/red]")


def get_git_aliases():
    """Dynamically fetch all git aliases from git config."""
    # Human-readable descriptions for known aliases
    alias_descriptions = {
        "alias": "List all git aliases in a formatted table",
        "branches": "Download all remote branches and create local tracking branches",
        "cleanup": "Delete branches with deleted remotes (merged). Use --force to also delete local-only branches",
        "main": "Switch to main with fetch, pull, and branch cleanup",
        "mainall": "Update main in every git repo in immediate subdirectories",
    }

    try:
        result = run_git("config", "--get-regexp", "alias", check=True)

        aliases = []
        for line in result.stdout.strip().split("\n"):
            if line:
                # Parse "alias.name value" format
                match = re.match(r"alias\.(.+?)\s+(.+)", line)
                if match:
                    alias_name = match.group(1)
                    alias_value = match.group(2)

                    # Use custom description if available, otherwise show the command
                    if alias_name in alias_descriptions:
                        description = alias_descriptions[alias_name]
                    elif alias_value.startswith("!"):
                        # For shell commands, show a cleaned up version
                        command = alias_value[1:]
                        if len(command) > 80:
                            description = f"Shell: {command[:77]}..."
                        else:
                            description = f"Shell: {command}"
                    else:
                        # For git sub-commands, show as-is but truncate if too long
                        if len(alias_value) > 80:
                            description = alias_value[:77] + "..."
                        else:
                            description = alias_value

                    aliases.append((alias_name, description))

        return sorted(aliases)
    except subprocess.CalledProcessError:
        return []


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


def update_all_main():
    """Run the switch-to-main flow for every git repo in immediate subdirectories.

    Scans the direct child directories of the current working directory, and for
    each one that is a git repository, runs switch_to_main() (fetch, switch to
    main, pull, branch cleanup). Repos with uncommitted changes are skipped by
    switch_to_main itself. Prints a per-repo header and a final summary table.

    Returns 0 if every repo succeeded, 1 if any repo failed (or none were found).
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

    results = []  # (repo_name, succeeded)
    for repo in repos:
        console.print(f"\n[bold]── {repo} ──[/bold]")
        try:
            os.chdir(repo)
            exit_code = switch_to_main()
        finally:
            os.chdir(original_cwd)
        results.append((repo, exit_code == 0))

    # Summary table
    table = Table(
        title="Update Summary", show_lines=True, header_style="bold yellow"
    )
    table.add_column("Repository", justify="left", style="cyan")
    table.add_column("Result", justify="left")

    for repo, succeeded in results:
        status = "[green]OK[/green]" if succeeded else "[red]Failed / skipped[/red]"
        table.add_row(repo, status)

    succeeded_count = sum(1 for _, ok in results if ok)
    console.print()
    console.print(table)
    console.print(
        f"\n[dim]Updated {succeeded_count} of {len(results)} repositories[/dim]"
    )

    return 0 if succeeded_count == len(results) else 1


def print_aliases():
    console = Console()
    table = Table(title="Git Aliases", show_lines=True, header_style="bold yellow")

    table.add_column("Alias", justify="left", style="cyan", no_wrap=True)
    table.add_column("Command/Description", justify="left", style="magenta")

    aliases = get_git_aliases()

    for alias, description in aliases:
        table.add_row(alias, description)

    console.print(table)
    console.print(f"\n[dim]Found {len(aliases)} git aliases[/dim]")


if __name__ == "__main__":
    if len(sys.argv) > 1:
        function_name = sys.argv[1]
        if function_name == "print_aliases":
            print_aliases()
        elif function_name == "cleanup":
            # Check for --force flag
            force = "--force" in sys.argv or "-f" in sys.argv
            cleanup_branches(force=force)
        elif function_name == "switch_to_main":
            exit_code = switch_to_main()
            sys.exit(exit_code)
        elif function_name == "update_all_main":
            sys.exit(update_all_main())
        else:
            print(f"Function {function_name} not found.")
    else:
        print("No function name provided.")
