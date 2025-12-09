# fuse-eth-fs

A FUSE filesystem backed by Ethereum smart contracts. Store files and directories on the blockchain!

## Overview

This project provides a two-component system combining Python and Solidity:

- **Python FUSE Implementation**: A Linux filesystem implementation using python-fuse that presents blockchain storage as a regular filesystem
- **Solidity Smart Contracts**: Basic functions for adding files and directories in contract storage

## Features

- ✅ **Account-based Home Directories**: Each Ethereum account has its own home directory under its address
- ✅ **Multi-Chain Support**: Supports multiple RPC URLs and chain IDs simultaneously
- ✅ **Auto Chain Detection**: Chain ID is automatically detected when connecting to an RPC endpoint
- ✅ **Virtual Filesystem Structure**: Chain IDs appear as the first level of the VFS hierarchy

## Virtual Filesystem Structure

```
/
├── <chain_id_1>/
│   ├── <account_address_1>/
│   │   ├── file1.txt
│   │   ├── dir1/
│   │   │   └── file2.txt
│   ├── <account_address_2>/
│   │   └── ...
├── <chain_id_2>/
│   └── ...
```

Example:
```
/1337/0x1234567890abcdef.../documents/report.pdf
```

## Prerequisites

- Python 3.8+
- Node.js and npm (for Hardhat)
- Linux with FUSE support
- An Ethereum RPC endpoint (local or remote)

## Installation

### 1. Clone the Repository

```bash
git clone https://github.com/Magicking/fuse-eth-fs.git
cd fuse-eth-fs
```

### 2. Install Python Dependencies

```bash
pip install -r requirements.txt
# Or install in development mode
pip install -e .
```

### 3. Install Solidity Dependencies

```bash
npm install
```

## Setup

### 1. Deploy Smart Contract

First, start a local Ethereum node (or use an existing one):

```bash
# Using Hardhat's built-in node
npx hardhat node
```

In another terminal, deploy the contract:

```bash
npx hardhat run scripts/deploy.js --network localhost
```

This will create a `deployment.json` file with the contract address and chain ID.

### 2. Configure Environment

Create a `.env` file:

```bash
# Single RPC URL
RPC_URL=http://127.0.0.1:8545

# Or multiple RPC URLs
RPC_URL_1=http://127.0.0.1:8545
RPC_URL_2=https://mainnet.infura.io/v3/YOUR_KEY

# Default account for operations
ETH_ACCOUNT=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

# Contract addresses (optional if using deployment.json)
CONTRACT_ADDRESS=0x5FbDB2315678afecb367f032d93F642f64180aa3
CHAIN_ID=1337
```

### 3. Mount the Filesystem

```bash
# Create a mount point
mkdir -p /tmp/ethfs

# Mount the filesystem
fuse-eth-fs /tmp/ethfs --foreground --debug

# Or use the Python module directly
python -m fuse_eth_fs.main /tmp/ethfs --foreground
```

## Usage

Once mounted, you can use the filesystem like any other:

```bash
# Navigate to your account's directory
cd /tmp/ethfs/1337/0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266/

# Create a file
echo "Hello, Blockchain!" > hello.txt

# Create a directory
mkdir documents

# Create a file in the directory
echo "My document" > documents/doc.txt

# Read files
cat hello.txt

# List files
ls -la

# Remove files
rm hello.txt
```

## Architecture

### Solidity Smart Contract (`contracts/FileSystem.sol`)

The smart contract provides:

- `createFile(path, content)`: Create a new file
- `createDirectory(path)`: Create a new directory
- `updateFile(path, content)`: Update file content
- `deleteEntry(path)`: Delete a file or directory
- `getEntry(account, path)`: Get file/directory information
- `getAccountPaths(account)`: List all paths for an account

### Python Components

1. **RPCManager** (`fuse_eth_fs/rpc_manager.py`): Manages multiple RPC connections and auto-detects chain IDs
2. **ContractManager** (`fuse_eth_fs/contract_manager.py`): Handles smart contract interactions
3. **EthFS** (`fuse_eth_fs/filesystem.py`): Main FUSE filesystem implementation

## Development

### Compile Smart Contracts

```bash
# Using Foundry
forge build

# Or using Hardhat (legacy)
npx hardhat compile
```

### Run Tests

The project includes comprehensive tests for both Solidity and Python components:

```bash
# Run all tests
make test

# Run only Solidity tests (using Foundry)
make test-solidity
# Or directly:
forge test -vv

# Run only Python tests
make test-python
# Or directly:
python -m pytest test/python/ -v
```

#### Solidity Tests

Solidity tests are written using Foundry's testing framework and are located in `test/solidity/`. These tests verify:
- File and directory creation
- Update and delete operations
- Access control and permissions
- Path listing functionality
- Multi-account isolation

#### Python Tests

Python tests use pytest and are located in `test/python/`. These tests verify:
- RPC connection management
- Path parsing logic
- Contract interaction layer
- Multi-chain support

### Project Structure

```
fuse-eth-fs/
├── contracts/              # Solidity smart contracts
│   └── FileSystem.sol
├── fuse_eth_fs/           # Python FUSE implementation
│   ├── __init__.py
│   ├── main.py            # Entry point
│   ├── filesystem.py      # FUSE filesystem class
│   ├── rpc_manager.py     # RPC connection manager
│   └── contract_manager.py # Smart contract interface
├── test/                  # Test files
│   ├── solidity/          # Foundry tests
│   │   └── FileSystem.t.sol
│   └── python/            # Python unit tests
│       ├── test_rpc_manager.py
│       ├── test_filesystem.py
│       └── test_contract_manager.py
├── scripts/               # Deployment scripts
│   └── deploy.js
├── foundry.toml          # Foundry configuration
├── hardhat.config.js     # Hardhat configuration (for deployment)
├── package.json          # Node.js dependencies
├── requirements.txt      # Python dependencies
├── setup.py             # Python package setup
├── Makefile             # Common development tasks
└── README.md            # This file
```

## Limitations & Future Improvements

- **Performance**: Blockchain operations are slow; consider caching
- **Gas Costs**: Every write operation costs gas
- **File Size**: Large files are expensive to store on-chain
- **Partial Writes**: Writes with offset > 0 are inefficient as they require reading the entire file from the blockchain before writing. This is expensive in terms of gas and network calls.
- **Permissions**: Basic permission system (owner-based)

Future improvements could include:
- IPFS integration for large file storage
- Advanced caching mechanisms to reduce blockchain reads
- Write buffering to minimize transaction costs
- Multiple account support with shared access
- Enhanced permission system
- Transaction batching for bulk operations

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

## License

MIT License - See LICENSE file for details

## Security Notice

This is a starter template for development and educational purposes. Do not use in production without proper security audits and testing.