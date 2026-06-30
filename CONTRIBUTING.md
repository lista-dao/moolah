# Contributing to Moolah

Thank you for your interest in contributing to Moolah! This document provides guidelines and instructions for contributing.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Workflow](#development-workflow)
- [Submitting Changes](#submitting-changes)
- [Style Guidelines](#style-guidelines)
- [Testing](#testing)
- [Security](#security)

## Code of Conduct

Please be respectful and constructive in all interactions. We are committed to providing a welcoming and inclusive environment for all contributors.

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) - Solidity development framework
- [Node.js](https://nodejs.org/) v18 or higher
- [Yarn](https://yarnpkg.com/) - Package manager
- [Git](https://git-scm.com/)

### Setup

1. Fork the repository on GitHub
2. Clone your fork:
   ```bash
   git clone --recursive git@github.com:YOUR_USERNAME/moolah.git
   cd moolah
   ```
3. Add the upstream repository:
   ```bash
   git remote add upstream git@github.com:lista-dao/moolah.git
   ```
4. Install dependencies:
   ```bash
   yarn install
   ```
5. Build the project:
   ```bash
   forge build
   ```

## Development Workflow

### Creating a Branch

Create a descriptive branch name for your changes:

```bash
git checkout -b feature/your-feature-name
# or
git checkout -b fix/issue-description
```

### Making Changes

1. Make your changes in the appropriate files
2. Write or update tests as needed
3. Ensure all tests pass
4. Format your code

### Running Tests

```bash
# Run all tests
forge test

# Run with verbosity
forge test -vvv

# Run specific test
forge test --match-contract ContractName --match-test testFunctionName -vvv

# Run with gas reporting
forge test --gas-report
```

### Formatting

Before committing, ensure your code is properly formatted:

```bash
forge fmt
```

## Submitting Changes

### Commit Messages

We follow the [Conventional Commits](https://www.conventionalcommits.org/) specification:

- `feat:` - New features
- `fix:` - Bug fixes
- `docs:` - Documentation changes
- `style:` - Code style changes (formatting, etc.)
- `refactor:` - Code refactoring without feature changes
- `test:` - Adding or updating tests
- `chore:` - Maintenance tasks

Examples:
```
feat: add new liquidation callback
fix: correct interest rate calculation
docs: update README with deployment instructions
test: add unit tests for MoolahVault
```

### Pull Request Process

1. Update your branch with the latest upstream changes:
   ```bash
   git fetch upstream
   git rebase upstream/master
   ```

2. Push your changes to your fork:
   ```bash
   git push origin your-branch-name
   ```

3. Open a Pull Request on GitHub against the `master` branch

4. In your PR description:
   - Describe what changes you made and why
   - Reference any related issues (e.g., "Fixes #123")
   - Include any relevant testing information
   - Add screenshots if applicable (for UI changes)

5. Wait for review and address any feedback

### PR Requirements

- All tests must pass
- Code must be formatted with `forge fmt`
- New features should include tests
- Documentation should be updated if needed

## Style Guidelines

### Solidity

- Use Solidity version `0.8.28`
- Follow the project's existing code style
- Use meaningful variable and function names
- Add NatSpec comments for public/external functions
- Keep functions focused and concise

### Documentation

- Use clear, concise language
- Update relevant documentation when making changes
- Include code examples where helpful

## Testing

### Writing Tests

- Place test files in the `test/` directory
- Name test files with `.t.sol` suffix
- Use descriptive test function names starting with `test`
- Test both success and failure cases
- Use fuzzing for numerical inputs where appropriate

### Test Coverage

Aim for comprehensive test coverage, especially for:
- Core protocol functions
- Edge cases
- Error conditions
- Access control

## Security

### Reporting Security Issues

**Do not report security vulnerabilities through public GitHub issues.**

Please report security issues directly to the Lista DAO team through responsible disclosure. See the security policy for details.

### Security Considerations

When contributing:
- Be mindful of reentrancy vulnerabilities
- Check for integer overflow/underflow
- Validate all inputs
- Follow the checks-effects-interactions pattern
- Consider gas optimization without sacrificing security

## Questions?

If you have questions about contributing, feel free to:
- Open a GitHub issue for discussion
- Reach out to the Lista DAO team

Thank you for contributing to Moolah! 🎉
