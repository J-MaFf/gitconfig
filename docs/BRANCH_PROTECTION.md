# Branch Protection Rules

This document outlines the branch protection rules configured for the `main` branch of this repository.

## Rules for `main` Branch

### 1. Require Pull Request Reviews

- **Minimum Reviews**: 1
- **Dismiss stale pull request approvals when new commits are pushed**: ✓ Enabled
- **Require review from code owners**: ✓ Enabled (if CODEOWNERS file exists)

### 2. Require Conversation Resolution

- **Require all conversations on code to be resolved before merging**: ✓ Enabled

### 3. Require Branches to be Up to Date

- **Require branches to be up to date before merging**: ✓ Enabled
- **Require status checks to pass before merging**: ✓ Enabled

### 4. Enforce Administration Rules

- **Restrict who can push to matching branches**: Administrator access only
- **Allow force pushes**: ✗ Disabled
- **Allow deletions**: ✗ Disabled
- **Lock branch**: Optional (use for critical releases)

### 5. Dismiss Stale Reviews

- **Automatically dismiss approvals when branches are updated**: ✓ Enabled

### 6. Require Code Owner Review (Optional)

- Use if a CODEOWNERS file is created
- Ensures designated code owners review relevant changes

## Setup Instructions

### Via GitHub Web Interface

1. Go to repository Settings → Branches
2. Click "Add rule" under "Branch protection rules"
3. Pattern to protect: `main`
4. Configure as follows:

   **Protection Settings:**
   - ✓ Require a pull request before merging (minimum 1 reviews)
   - ✓ Dismiss stale pull request approvals when new commits are pushed
   - ✓ Require review from Code Owners
   - ✓ Require conversation resolution before merging
   - ✓ Require status checks to pass before merging
   - ✓ Require branches to be up to date before merging
   - ✗ Do NOT allow force pushes
   - ✗ Do NOT allow deletions

5. Click "Create" to apply rules

### Via GitHub CLI (PowerShell)

```powershell
$protection = @{
  required_status_checks = @{
    strict = $true
    contexts = @()
  }
  enforce_admins = $true
  required_pull_request_reviews = @{
    dismiss_stale_reviews = $true
    require_code_owner_reviews = $true
    require_last_push_approval = $true
    required_approving_review_count = 1
  }
  restrictions = $null
  allow_force_pushes = $false
  allow_deletions = $false
  block_creations = $false
  required_conversation_resolution = $true
  lock_branch = $false
}

$protection | ConvertTo-Json | gh api repos/J-MaFf/gitconfig/branches/main/protection --input - -X PUT
```

## Rationale

### Why These Rules?

1. **Pull Request Reviews**: Ensures code quality and prevents accidental changes to main
2. **Conversation Resolution**: Requires discussion of any feedback before merging
3. **Up-to-Date Branches**: Prevents merge conflicts and ensures main is always stable
4. **No Force Pushes**: Protects history integrity and prevents data loss
5. **No Deletions**: Prevents accidental branch deletion
6. **Stale Review Dismissal**: Ensures reviews reflect current code changes

### For This Project

- **Pre-release Phase**: While in `v0.1.0-pre`, these rules help maintain code quality
- **Semantic Versioning**: Protects tagged releases on main from unintended changes
- **Cross-Machine Setup**: Ensures all machines get stable, tested configuration
- **Documentation**: Main should only have thoroughly reviewed and documented changes

## Enforcement for Admins

By default, admins bypass some protection rules. Consider:

- Always use pull requests even as admin
- Require status checks even for admins
- Enable "Dismiss stale reviews" to ensure fresh review with each push

## Future Enhancements

As the project grows, consider adding:

- Automatic status checks (CI/CD pipeline tests)
- Code coverage requirements
- Automated deployment on merge to main
- Required checks for semantic versioning compliance

## References

- [GitHub Branch Protection Documentation](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/managing-a-branch-protection-rule)
- [GitHub REST API - Update Branch Protection](https://docs.github.com/en/rest/branches/branch-protection?apiVersion=2022-11-28)
