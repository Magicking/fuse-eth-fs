// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IFileSystem} from "../../IFileSystem.sol";

/**
 * @title IRPCProxyPlugin
 * @dev Extension of IFileSystem for plugins that need off-chain RPC calls.
 * The contract describes what RPC call to make via getRPCDescriptor(),
 * the Python FUSE layer executes it, then calls formatRPCResult() to
 * produce human-readable file content.
 */
interface IRPCProxyPlugin is IFileSystem {
    enum RPCCallType { STORAGE_AT, CALL, GET_CODE, GAS_PRICE, BLOCK_NUMBER, GET_BALANCE }

    struct RPCDescriptor {
        RPCCallType callType;
        address targetAddress;     // target contract
        bytes callData;            // storage slot (bytes32) or eth_call calldata
        uint256 blockNumber;       // 0 = latest
    }

    /// @dev Given a storage slot (file ID), return what RPC call to make
    function getRPCDescriptor(uint256 storageSlot)
        external view returns (RPCDescriptor memory descriptor);

    /// @dev Format raw RPC result into file content
    function formatRPCResult(uint256 storageSlot, bytes memory rpcResult)
        external view returns (bytes memory formattedContent);

    /// @dev Identify this contract as an RPC proxy plugin
    function isRPCProxy() external pure returns (bool);
}
