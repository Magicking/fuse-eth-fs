"""
Main entry point for FUSE-eth-fs
"""

import argparse
import os
import sys
from fuse import FUSE

from .filesystem import EthFS


def main():
    """Main entry point"""
    parser = argparse.ArgumentParser(
        description='Mount an Ethereum-backed FUSE filesystem'
    )
    parser.add_argument(
        'mountpoint',
        help='Directory where the filesystem will be mounted'
    )
    parser.add_argument(
        '--contract',
        help='Contract address (can specify multiple with --contract CHAIN_ID:ADDRESS)',
        action='append',
        default=[]
    )
    parser.add_argument(
        '--foreground',
        '-f',
        action='store_true',
        help='Run in foreground'
    )
    parser.add_argument(
        '--debug',
        '-d',
        action='store_true',
        help='Enable debug output'
    )
    
    args = parser.parse_args()
    
    # Parse contract addresses
    contract_addresses = {}
    
    if not args.contract:
        # Try to load from environment or deployment.json
        if os.path.exists('deployment.json'):
            import json
            with open('deployment.json', 'r') as f:
                deployment = json.load(f)
                chain_id = int(deployment.get('chainId', 1337))
                address = deployment.get('address')
                if address:
                    contract_addresses[chain_id] = address
                    print(f"Loaded contract from deployment.json: {chain_id}:{address}")
        
        # Also check environment variable
        contract_env = os.environ.get('CONTRACT_ADDRESS')
        chain_env = os.environ.get('CHAIN_ID', '1337')
        if contract_env:
            contract_addresses[int(chain_env)] = contract_env
            print(f"Loaded contract from environment: {chain_env}:{contract_env}")
    else:
        # Parse from command line arguments
        for contract_spec in args.contract:
            if ':' in contract_spec:
                chain_id_str, address = contract_spec.split(':', 1)
                chain_id = int(chain_id_str)
            else:
                # Default to chain ID 1337 if not specified
                chain_id = 1337
                address = contract_spec
            
            contract_addresses[chain_id] = address
            print(f"Using contract: {chain_id}:{address}")
    
    if not contract_addresses:
        print("Error: No contract addresses specified!")
        print("Specify with --contract CHAIN_ID:ADDRESS or set CONTRACT_ADDRESS environment variable")
        sys.exit(1)
    
    # Create and mount filesystem
    print(f"Mounting filesystem at {args.mountpoint}")
    print("Press Ctrl+C to unmount")
    
    fuse_options = {
        'foreground': args.foreground or args.debug,
        'allow_other': False,
        'auto_unmount': True,
    }
    
    if args.debug:
        fuse_options['debug'] = True
    
    try:
        FUSE(
            EthFS(contract_addresses),
            args.mountpoint,
            **fuse_options
        )
    except KeyboardInterrupt:
        print("\nUnmounting filesystem...")
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)


if __name__ == '__main__':
    main()
