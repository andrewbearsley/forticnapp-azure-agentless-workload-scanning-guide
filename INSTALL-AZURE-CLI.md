# Installing and Configuring Azure CLI

## Installation

### macOS

Install using Homebrew:
```bash
brew install azure-cli
```

### Windows

Install using Chocolatey:
```powershell
choco install azure-cli
```

### Verify Installation

```bash
az --version
```

## Configuration

### Login to Azure

```bash
az login
```

This opens a browser window for authentication.

### Verify Subscription Access

```bash
az account list
```

To set a default subscription:
```bash
az account set --subscription <subscription-id>
```

## Reference

- [Azure CLI Documentation](https://learn.microsoft.com/en-us/cli/azure/)
