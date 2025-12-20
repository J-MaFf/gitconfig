# Dependencies: rich
# To install dependencies, run: python -m pip install rich
# To test that rich is installed, run: python -m rich
#
# This script is machine-agnostic and designed to work from any installation directory.
# It dynamically locates git configuration and operates on the current repository.

import sys
import subprocess
import re

try:
    from rich.console import Console
    from rich.table import Table
except ImportError:
    print("The 'rich' library is not installed. Attempting to install it now...")
    subprocess.check_call([sys.executable, "-m", "pip", "install", "rich"])
    from rich.console import Console
    from rich.table import Table


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
            subprocess.run(
                ["git", "rev-parse", "--git-dir"], capture_output=True, text=True, check=True
            )
        except subprocess.CalledProcessError:
            console.print("[red]Error: Not in a git repository[/red]")
            return

        # Get current branch
        result_current = subprocess.run(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"], capture_output=True, text=True, check=True
        )
        current_branch = result_current.stdout.strip()
        switched_branch = False

        # Switch to main if not already on it
        if current_branch != "main":
            console.print(f"[cyan]Switching from '{current_branch}' to 'main'...[/cyan]")
            result = subprocess.run(["git", "checkout", "main"], capture_output=True, text=True, check=False)
            if result.returncode != 0:
                console.print("[red]Error: Failed to switch to main branch[/red]")
                console.print(f"[red]{result.stderr.strip()}[/red]")
                return
            switched_branch = True

        # Get all branches before cleanup
        result_before = subprocess.run(
            ["git", "branch", "-vv"], capture_output=True, text=True, check=True
        )
        branches_before = set(
            line.strip().split()[0].lstrip("*").strip()
            for line in result_before.stdout.strip().split("\n")
            if line.strip()
        )

        # Run the actual cleanup command (not the alias to avoid recursion)
        console.print("[cyan]Running git cleanup...[/cyan]")
        subprocess.run(["git", "fetch", "-p"], check=False)

        # Get list of branches to delete:
        # 1. Branches with no remote tracking (no [origin/...] in output) - requires confirmation
        # 2. Branches where the remote has been deleted (contains ": gone]") - auto-delete
        result_vv = subprocess.run(
            ["git", "branch", "-vv"], capture_output=True, text=True, check=False
        )

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

            if has_no_remote:
                # Auto-delete branches with no remote tracking (merged/deleted remotes)
                branches_to_delete.append(branch_name)
            elif remote_is_gone and force:
                # Delete branches where remote explicitly marked as gone if --force specified
                branches_to_delete.append(branch_name)

        # Delete the identified branches
        for branch in branches_to_delete:
            result = subprocess.run(["git", "branch", "-D", branch], capture_output=True, text=True, check=False)
            if result.returncode != 0:
                console.print(f"[yellow]Warning: Failed to delete branch '{branch}': {result.stderr.strip()}[/yellow]")

        # Get all branches after cleanup
        result_after = subprocess.run(
            ["git", "branch", "-vv"], capture_output=True, text=True, check=True
        )
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
                console.print(f"[yellow]Note: Your original branch '{current_branch}' was deleted during cleanup.[/yellow]")
                console.print("[cyan]Staying on 'main'.[/cyan]\n")
            else:
                console.print(f"[cyan]Switching back to '{current_branch}'...[/cyan]")
                result = subprocess.run(["git", "checkout", current_branch], capture_output=True, text=True, check=False)
                if result.returncode != 0:
                    console.print(f"[yellow]Warning: Failed to switch back to '{current_branch}'[/yellow]")
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
    }

    try:
        # Get all aliases from git config
        result = subprocess.run(
            ["git", "config", "--get-regexp", "alias"],
            capture_output=True,
            text=True,
            check=True,
        )

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
        return [
            ("alias", "List all aliases"),
            ("branches", "Track all remote branches"),
            ("cleanup", "Cleanup merged branches"),
        ]


def switch_to_main():
    """Switch to main branch with full error handling and conflict detection.
    
    Steps:
    1. Verify we're in a git repository
    2. Fetch updates from remote
    3. Check for uncommitted changes
    4. Switch to main branch
    5. Pull latest changes
    6. Detect and report merge conflicts
    """
    console = Console()

    try:
        # Step 1: Verify git repository
        result = subprocess.run(
            ["git", "rev-parse", "--git-dir"], capture_output=True, text=True, check=False
        )
        if result.returncode != 0:
            console.print("[red]Error: Not in a git repository[/red]")
            return 1

        # Get current branch
        result_current = subprocess.run(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"], capture_output=True, text=True, check=True
        )
        current_branch = result_current.stdout.strip()

        # Step 2: Fetch updates
        console.print("[cyan]Fetching updates from remote...[/cyan]")
        result = subprocess.run(["git", "fetch", "-p"], capture_output=True, text=True, check=False)
        if result.returncode != 0:
            console.print("[red]Error: Failed to fetch from remote[/red]")
            console.print(f"[red]{result.stderr.strip()}[/red]")
            return 1
        console.print("[green]✓ Fetch complete[/green]")

        # Step 3: Check for uncommitted changes
        result_status = subprocess.run(
            ["git", "status", "--porcelain"], capture_output=True, text=True, check=True
        )
        if result_status.stdout.strip():
            console.print("[red]Error: Uncommitted changes detected[/red]")
            console.print("[yellow]Please commit or stash your changes before switching to main:[/yellow]")
            console.print(result_status.stdout)
            return 1

        # Step 4: Switch to main (if not already there)
        if current_branch != "main":
            console.print(f"[cyan]Switching from '{current_branch}' to 'main'...[/cyan]")
            result = subprocess.run(["git", "checkout", "main"], capture_output=True, text=True, check=False)
            if result.returncode != 0:
                console.print("[red]Error: Failed to checkout main branch[/red]")
                console.print(f"[red]{result.stderr.strip()}[/red]")
                return 1
            console.print("[green]✓ Switched to main[/green]")
        else:
            console.print("[cyan]Already on main branch[/cyan]")

        # Step 5: Pull latest changes
        console.print("[cyan]Pulling latest changes...[/cyan]")
        result = subprocess.run(["git", "pull"], capture_output=True, text=True, check=False)
        
        if result.returncode != 0:
            # Check if it's a merge conflict
            result_status = subprocess.run(
                ["git", "status", "--porcelain"], capture_output=True, text=True, check=True
            )
            
            if "UU" in result_status.stdout or "AA" in result_status.stdout or "DD" in result_status.stdout:
                console.print("[red]✗ Merge conflict detected during pull![/red]")
                console.print("[yellow]Resolve conflicts and commit:[/yellow]")
                console.print(result_status.stdout)
                console.print("[cyan]After resolving, run: git add . && git commit[/cyan]")
                return 1
            else:
                console.print("[red]Error: Pull failed[/red]")
                console.print(f"[red]{result.stderr.strip()}[/red]")
                return 1
        
        console.print("[green]✓ Pull complete[/green]")
        console.print("[green]✓ Successfully switched to main and updated![/green]")
        return 0

    except subprocess.CalledProcessError as e:
        console.print(f"[red]Error: {e}[/red]")
        return 1


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
        else:
            print(f"Function {function_name} not found.")
    else:
        print("No function name provided.")
