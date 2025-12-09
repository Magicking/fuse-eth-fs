.PHONY: install compile deploy test test-solidity test-python clean mount help

help:
	@echo "fuse-eth-fs - Makefile commands"
	@echo ""
	@echo "Setup:"
	@echo "  make install       - Install all dependencies"
	@echo "  make compile       - Compile smart contracts with Foundry"
	@echo ""
	@echo "Development:"
	@echo "  make node          - Start local Hardhat node"
	@echo "  make deploy        - Deploy contracts to local network"
	@echo "  make test          - Run all tests (Solidity + Python)"
	@echo "  make test-solidity - Run Solidity tests with Foundry"
	@echo "  make test-python   - Run Python unit tests"
	@echo ""
	@echo "Usage:"
	@echo "  make mount         - Mount filesystem (needs deployment first)"
	@echo "  make mount-debug   - Mount filesystem with debug output"
	@echo ""
	@echo "Cleanup:"
	@echo "  make clean         - Clean build artifacts"

install:
	@echo "Installing Python dependencies..."
	pip install -r requirements.txt
	@echo "Installing Node.js dependencies..."
	npm install
	@echo "Installation complete!"

compile:
	@echo "Compiling smart contracts with Foundry..."
	forge build

node:
	@echo "Starting Hardhat node..."
	npx hardhat node

deploy:
	@echo "Deploying contracts..."
	npx hardhat run scripts/deploy.js --network localhost

test: test-solidity test-python

test-solidity:
	@echo "Running Solidity tests with Foundry..."
	forge test -vv

test-python:
	@echo "Running Python unit tests..."
	python -m pytest test/python/ -v

mount:
	@echo "Creating mount point..."
	@mkdir -p /tmp/ethfs
	@echo "Mounting filesystem at /tmp/ethfs"
	@echo "Press Ctrl+C to unmount"
	python -m fuse_eth_fs.main /tmp/ethfs --foreground

mount-debug:
	@echo "Creating mount point..."
	@mkdir -p /tmp/ethfs
	@echo "Mounting filesystem at /tmp/ethfs (debug mode)"
	@echo "Press Ctrl+C to unmount"
	python -m fuse_eth_fs.main /tmp/ethfs --foreground --debug

clean:
	@echo "Cleaning build artifacts..."
	rm -rf cache/ artifacts/ node_modules/ __pycache__/ 
	rm -rf fuse_eth_fs/__pycache__/ *.egg-info/ build/ dist/
	rm -rf out/ cache_forge/ lib/
	rm -rf test/python/__pycache__/
	rm -f deployment.json
	@echo "Clean complete!"
