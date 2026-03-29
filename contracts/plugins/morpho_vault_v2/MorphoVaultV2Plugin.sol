// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IFileSystem} from "../../IFileSystem.sol";
import {IRPCProxyPlugin} from "../rpc_proxy/IRPCProxyPlugin.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title MorphoVaultV2Plugin
 * @dev RPC proxy plugin that exposes all metrics from a Morpho VaultV2 contract.
 * Instantiated with the VaultV2 address directly. Metrics are organized in a
 * directory structure mirroring the vault's logical sections:
 *
 *   token/           - ERC20 identity (name, symbol, decimals, totalSupply)
 *   erc4626/         - ERC4626 share-price views (totalAssets, convertToShares, etc.)
 *   fees/            - Performance & management fee configuration
 *   interest/        - Interest accrual state (_totalAssets, lastUpdate, maxRate, accrueInterestView)
 *   roles/           - Owner, curator, gates, adapter registry
 *   adapters/        - Adapter count, liquidity adapter config
 */
contract MorphoVaultV2Plugin is IRPCProxyPlugin {
    using Strings for uint256;

    // ============ Types ============

    enum FormatType {
        UINT256,           // raw uint256
        UINT256_WAD,       // uint256 / 1e18 with decimal point
        UINT128,           // raw uint128 (cast from uint128 return)
        UINT64,            // raw uint64
        UINT8,             // uint8 (e.g. decimals)
        UINT96_WAD,        // uint96 fee in WAD
        ADDRESS,           // address (hex)
        STRING_RESULT,     // ABI-encoded string return
        BOOL,              // "true" or "false"
        ACCRUE_VIEW,       // accrueInterestView() -> (uint256, uint256, uint256)
        BYTES_RESULT,      // raw bytes return (hex)
        ASSET_DECIMALS,    // uint256 formatted with vault's asset decimals (dynamic)
        TIMELOCK_PARAMS    // BATCH_CALL: [timelock(bytes4), abdicated(bytes4)] -> duration + bool
    }

    struct MetricDef {
        bytes4 selector;
        FormatType formatType;
    }

    // ============ State ============

    address public immutable vault;
    uint256 public immutable metricCount;
    uint256 public immutable dirCount;
    uint256 public immutable totalEntries;

    MetricDef[] private _metrics;
    string[] private _metricNames;
    string[] private _dirNames;

    // ============ Errors ============

    error NotImplemented();
    error SlotOutOfRange();

    // ============ Constructor ============

    constructor(address _vault) {
        vault = _vault;
        _initMetrics();
        _initAbdicationMetrics();
        _initDirs();
        metricCount = _metrics.length;
        dirCount = _dirNames.length;
        totalEntries = _metrics.length + _dirNames.length;
    }

    // ============ IRPCProxyPlugin ============

    function isRPCProxy() external pure override returns (bool) {
        return true;
    }

    function getRPCDescriptor(uint256 storageSlot)
        external
        view
        override
        returns (RPCDescriptor memory descriptor)
    {
        if (storageSlot >= metricCount) revert SlotOutOfRange();

        descriptor = _getRPCDescriptorInternal(storageSlot);
    }

    function formatRPCResult(uint256 storageSlot, bytes memory rpcResult)
        external
        view
        override
        returns (bytes memory formattedContent)
    {
        if (storageSlot >= metricCount) revert SlotOutOfRange();

        MetricDef storage m = _metrics[storageSlot];
        string storage metricName = _metricNames[storageSlot];

        formattedContent = _formatValue(rpcResult, m.formatType, metricName);
    }

    // ============ IFileSystem ============

    function getEntry(uint256 storageSlot)
        external
        view
        override
        returns (
            EntryType entryType,
            address owner,
            bytes memory name,
            bytes memory body,
            uint256 timestamp,
            bool entryExists,
            uint256 fileSize,
            address directoryTarget
        )
    {
        if (storageSlot >= totalEntries) {
            return (EntryType.FILE, address(0), "", "", 0, false, 0, address(0));
        }

        if (storageSlot >= metricCount) {
            uint256 dirIdx = storageSlot - metricCount;
            return (
                EntryType.DIRECTORY,
                address(this),
                bytes(_dirNames[dirIdx]),
                "",
                block.timestamp,
                true,
                0,
                address(0)
            );
        }

        return (
            EntryType.FILE,
            address(this),
            bytes(_metricNames[storageSlot]),
            "",
            block.timestamp,
            true,
            0,
            address(0)
        );
    }

    function getEntries() external view override returns (uint256[] memory) {
        uint256[] memory entries = new uint256[](totalEntries);
        for (uint256 i = 0; i < totalEntries; i++) {
            entries[i] = i;
        }
        return entries;
    }

    function getEntryCount() external view override returns (uint256) {
        return totalEntries;
    }

    function getEntriesPaginated(uint256 offset, uint256 limit)
        external
        view
        override
        returns (uint256[] memory)
    {
        if (offset >= totalEntries) return new uint256[](0);

        uint256 remaining = totalEntries - offset;
        uint256 count = limit < remaining ? limit : remaining;
        uint256[] memory entries = new uint256[](count);

        for (uint256 i = 0; i < count; i++) {
            entries[i] = offset + i;
        }
        return entries;
    }

    function exists(uint256 storageSlot) external view override returns (bool) {
        return storageSlot < totalEntries;
    }

    function readFile(uint256, uint256, uint256) external pure override returns (bytes memory) {
        return "";
    }

    function readCluster(uint256, uint256) external pure override returns (uint256) {
        return 0;
    }

    function createFile(bytes memory, bytes memory, uint256) external pure override {
        revert NotImplemented();
    }

    function createDirectory(bytes memory, address) external pure override {
        revert NotImplemented();
    }

    function updateFile(uint256, bytes memory, uint256) external pure override {
        revert NotImplemented();
    }

    function deleteEntry(uint256) external pure override {
        revert NotImplemented();
    }

    function writeFile(uint256, uint256, bytes memory) external pure override {
        revert NotImplemented();
    }

    // ============ Metric Initialization ============

    function _add(bytes4 sel, string memory metricName, FormatType fmt) internal {
        _metrics.push(MetricDef({selector: sel, formatType: fmt}));
        _metricNames.push(metricName);
    }

    function _initMetrics() internal {
        // ── token/ ── ERC20 identity
        _add(bytes4(keccak256("name()")),        "token/name",        FormatType.STRING_RESULT);
        _add(bytes4(keccak256("symbol()")),      "token/symbol",      FormatType.STRING_RESULT);
        _add(bytes4(keccak256("decimals()")),    "token/decimals",    FormatType.UINT8);
        _add(bytes4(keccak256("totalSupply()")), "token/totalSupply", FormatType.UINT256_WAD);
        _add(bytes4(keccak256("asset()")),       "token/asset",       FormatType.ADDRESS);

        // ── erc4626/ ── Share price & conversion views
        _add(bytes4(keccak256("totalAssets()")),      "erc4626/totalAssets",      FormatType.ASSET_DECIMALS);
        _add(bytes4(keccak256("virtualShares()")),    "erc4626/virtualShares",    FormatType.UINT256);
        // previewDeposit(1e18) - how many shares for 1 full token
        _add(bytes4(keccak256("previewDeposit(uint256)")),  "erc4626/previewDeposit_1e18",  FormatType.UINT256_WAD);
        // previewMint(1e18) - how many assets for 1 full share
        _add(bytes4(keccak256("previewMint(uint256)")),     "erc4626/previewMint_1e18",     FormatType.ASSET_DECIMALS);
        // previewRedeem(1e18) - assets returned per full share
        _add(bytes4(keccak256("previewRedeem(uint256)")),   "erc4626/previewRedeem_1e18",   FormatType.ASSET_DECIMALS);
        // previewWithdraw(1e18) - shares needed per full token
        _add(bytes4(keccak256("previewWithdraw(uint256)")), "erc4626/previewWithdraw_1e18", FormatType.UINT256_WAD);

        // ── fees/ ── Fee configuration
        _add(bytes4(keccak256("performanceFee()")),          "fees/performanceFee",          FormatType.UINT96_WAD);
        _add(bytes4(keccak256("performanceFeeRecipient()")), "fees/performanceFeeRecipient", FormatType.ADDRESS);
        _add(bytes4(keccak256("managementFee()")),           "fees/managementFee",           FormatType.UINT96_WAD);
        _add(bytes4(keccak256("managementFeeRecipient()")),  "fees/managementFeeRecipient",  FormatType.ADDRESS);

        // ── interest/ ── Interest accrual state
        _add(bytes4(keccak256("_totalAssets()")),         "interest/lastRecordedTotalAssets", FormatType.ASSET_DECIMALS);
        _add(bytes4(keccak256("lastUpdate()")),           "interest/lastUpdate",              FormatType.UINT64);
        _add(bytes4(keccak256("maxRate()")),              "interest/maxRate",                 FormatType.UINT64);
        _add(bytes4(keccak256("accrueInterestView()")),   "interest/accrueInterestView",     FormatType.ACCRUE_VIEW);

        // ── roles/ ── Access control & gates
        _add(bytes4(keccak256("owner()")),             "roles/owner",             FormatType.ADDRESS);
        _add(bytes4(keccak256("curator()")),           "roles/curator",           FormatType.ADDRESS);
        _add(bytes4(keccak256("receiveSharesGate()")), "roles/receiveSharesGate", FormatType.ADDRESS);
        _add(bytes4(keccak256("sendSharesGate()")),    "roles/sendSharesGate",    FormatType.ADDRESS);
        _add(bytes4(keccak256("receiveAssetsGate()")), "roles/receiveAssetsGate", FormatType.ADDRESS);
        _add(bytes4(keccak256("sendAssetsGate()")),    "roles/sendAssetsGate",    FormatType.ADDRESS);
        _add(bytes4(keccak256("adapterRegistry()")),   "roles/adapterRegistry",   FormatType.ADDRESS);

        // ── adapters/ ── Adapter state
        _add(bytes4(keccak256("adaptersLength()")),    "adapters/count",            FormatType.UINT256);
        _add(bytes4(keccak256("liquidityAdapter()")),  "adapters/liquidityAdapter", FormatType.ADDRESS);
        _add(bytes4(keccak256("liquidityData()")),     "adapters/liquidityData",    FormatType.BYTES_RESULT);
    }

    function _getRPCDescriptorInternal(uint256 storageSlot)
        internal
        view
        returns (RPCDescriptor memory descriptor)
    {
        MetricDef storage m = _metrics[storageSlot];

        // Timelock params: BATCH_CALL [timelock(bytes4), abdicated(bytes4)]
        if (m.formatType == FormatType.TIMELOCK_PARAMS) {
            address[] memory targets = new address[](2);
            targets[0] = vault;
            targets[1] = vault;
            bytes[] memory calldatas = new bytes[](2);
            calldatas[0] = abi.encodeWithSelector(bytes4(keccak256("timelock(bytes4)")), m.selector);
            calldatas[1] = abi.encodeWithSelector(bytes4(0xe470b8bc), m.selector);
            return RPCDescriptor({
                callType: RPCCallType.BATCH_CALL,
                targetAddress: address(0),
                callData: abi.encode(targets, calldatas),
                blockNumber: 0
            });
        }

        // For preview functions, encode 1e18 as argument
        bytes memory callData;
        if (m.selector == bytes4(keccak256("previewDeposit(uint256)")) ||
            m.selector == bytes4(keccak256("previewMint(uint256)")) ||
            m.selector == bytes4(keccak256("previewRedeem(uint256)")) ||
            m.selector == bytes4(keccak256("previewWithdraw(uint256)")))
        {
            callData = abi.encodeWithSelector(m.selector, uint256(1e18));
        } else {
            callData = abi.encodePacked(m.selector);
        }

        descriptor = RPCDescriptor({
            callType: RPCCallType.CALL,
            targetAddress: vault,
            callData: callData,
            blockNumber: 0
        });
    }

    function _initAbdicationMetrics() internal {
        _add(bytes4(keccak256("setIsAllocator(address,bool)")),               "timelocks/setIsAllocator",               FormatType.TIMELOCK_PARAMS);
        _add(bytes4(keccak256("setReceiveSharesGate(address)")),              "timelocks/setReceiveSharesGate",         FormatType.TIMELOCK_PARAMS);
        _add(bytes4(keccak256("setSendSharesGate(address)")),                 "timelocks/setSendSharesGate",            FormatType.TIMELOCK_PARAMS);
        _add(bytes4(keccak256("setReceiveAssetsGate(address)")),              "timelocks/setReceiveAssetsGate",         FormatType.TIMELOCK_PARAMS);
        _add(bytes4(keccak256("setSendAssetsGate(address)")),                 "timelocks/setSendAssetsGate",            FormatType.TIMELOCK_PARAMS);
        _add(bytes4(keccak256("setAdapterRegistry(address)")),                "timelocks/setAdapterRegistry",           FormatType.TIMELOCK_PARAMS);
        _add(bytes4(keccak256("addAdapter(address)")),                        "timelocks/addAdapter",                   FormatType.TIMELOCK_PARAMS);
        _add(bytes4(keccak256("removeAdapter(address)")),                     "timelocks/removeAdapter",                FormatType.TIMELOCK_PARAMS);
        _add(bytes4(keccak256("increaseTimelock(bytes4,uint256)")),           "timelocks/increaseTimelock",             FormatType.TIMELOCK_PARAMS);
        _add(bytes4(keccak256("decreaseTimelock(bytes4,uint256)")),           "timelocks/decreaseTimelock",             FormatType.TIMELOCK_PARAMS);
        _add(bytes4(keccak256("abdicate(bytes4)")),                           "timelocks/abdicate",                     FormatType.TIMELOCK_PARAMS);
        _add(bytes4(keccak256("setPerformanceFee(uint256)")),                 "timelocks/setPerformanceFee",            FormatType.TIMELOCK_PARAMS);
        _add(bytes4(keccak256("setManagementFee(uint256)")),                  "timelocks/setManagementFee",             FormatType.TIMELOCK_PARAMS);
        _add(bytes4(keccak256("setPerformanceFeeRecipient(address)")),        "timelocks/setPerformanceFeeRecipient",   FormatType.TIMELOCK_PARAMS);
        _add(bytes4(keccak256("setManagementFeeRecipient(address)")),         "timelocks/setManagementFeeRecipient",    FormatType.TIMELOCK_PARAMS);
        _add(bytes4(keccak256("increaseAbsoluteCap(bytes,uint256)")),         "timelocks/increaseAbsoluteCap",          FormatType.TIMELOCK_PARAMS);
        _add(bytes4(keccak256("increaseRelativeCap(bytes,uint256)")),         "timelocks/increaseRelativeCap",          FormatType.TIMELOCK_PARAMS);
        _add(bytes4(keccak256("setForceDeallocatePenalty(address,uint256)")), "timelocks/setForceDeallocatePenalty",    FormatType.TIMELOCK_PARAMS);
    }

    function _initDirs() internal {
        _dirNames.push("token");
        _dirNames.push("erc4626");
        _dirNames.push("fees");
        _dirNames.push("interest");
        _dirNames.push("roles");
        _dirNames.push("adapters");
        _dirNames.push("timelocks");
    }

    // ============ Formatting ============

    function _formatValue(bytes memory raw, FormatType fmt, string storage metricName)
        internal
        view
        returns (bytes memory)
    {
        if (fmt == FormatType.UINT256) {
            uint256 val = _decodeUint256(raw);
            return abi.encodePacked(metricName, "\n", val.toString(), "\n");
        }

        if (fmt == FormatType.UINT256_WAD) {
            uint256 val = _decodeUint256(raw);
            return abi.encodePacked(metricName, "\n", _formatDecimals(val, 18), "\n");
        }

        if (fmt == FormatType.UINT128 || fmt == FormatType.ASSET_DECIMALS) {
            uint256 val = _decodeUint256(raw);
            // ASSET_DECIMALS: we format with 18 decimals as default since most assets are 18-dec.
            // For 6-decimal assets (USDC), the raw value will still be readable.
            if (fmt == FormatType.ASSET_DECIMALS) {
                return abi.encodePacked(metricName, "\n", _formatDecimals(val, 18), "\n");
            }
            return abi.encodePacked(metricName, "\n", val.toString(), "\n");
        }

        if (fmt == FormatType.UINT64) {
            uint256 val = _decodeUint256(raw);
            return abi.encodePacked(metricName, "\n", val.toString(), "\n");
        }

        if (fmt == FormatType.UINT8) {
            uint256 val = _decodeUint256(raw);
            return abi.encodePacked(metricName, "\n", val.toString(), "\n");
        }

        if (fmt == FormatType.UINT96_WAD) {
            uint256 val = _decodeUint256(raw);
            return abi.encodePacked(metricName, "\n", _formatWadPercent(val), "\n");
        }

        if (fmt == FormatType.ADDRESS) {
            address val = _decodeAddress(raw);
            return abi.encodePacked(metricName, "\n", _toAddressString(val), "\n");
        }

        if (fmt == FormatType.STRING_RESULT) {
            string memory val = _decodeString(raw);
            return abi.encodePacked(metricName, "\n", val, "\n");
        }

        if (fmt == FormatType.BOOL) {
            uint256 val = _decodeUint256(raw);
            return abi.encodePacked(metricName, "\n", val != 0 ? "true" : "false", "\n");
        }

        if (fmt == FormatType.ACCRUE_VIEW) {
            return _formatAccrueView(raw, metricName);
        }

        if (fmt == FormatType.BYTES_RESULT) {
            return abi.encodePacked(metricName, "\n", _toHexString(raw), "\n");
        }

        if (fmt == FormatType.TIMELOCK_PARAMS) {
            return _formatTimelockParams(raw, metricName);
        }

        return abi.encodePacked(metricName, "\n", _toHexString(raw), "\n");
    }

    function _formatAccrueView(bytes memory raw, string storage metricName)
        internal
        pure
        returns (bytes memory)
    {
        // accrueInterestView() returns (uint256 newTotalAssets, uint256 perfFeeShares, uint256 mgmtFeeShares)
        uint256 newTotalAssets = _decodeUint256At(raw, 0);
        uint256 perfFeeShares = _decodeUint256At(raw, 32);
        uint256 mgmtFeeShares = _decodeUint256At(raw, 64);
        return abi.encodePacked(
            metricName, "\n",
            "newTotalAssets:       ", _formatDecimals(newTotalAssets, 18), "\n",
            "performanceFeeShares: ", _formatDecimals(perfFeeShares, 18), "\n",
            "managementFeeShares:  ", _formatDecimals(mgmtFeeShares, 18), "\n"
        );
    }

    // ============ Decoding Helpers ============

    function _decodeUint256(bytes memory data) internal pure returns (uint256 val) {
        if (data.length < 32) return 0;
        assembly {
            val := mload(add(data, 32))
        }
    }

    function _decodeUint256At(bytes memory data, uint256 offset) internal pure returns (uint256 val) {
        if (data.length < offset + 32) return 0;
        assembly {
            val := mload(add(add(data, 32), offset))
        }
    }

    function _decodeAddress(bytes memory data) internal pure returns (address val) {
        if (data.length < 32) return address(0);
        uint256 raw;
        assembly {
            raw := mload(add(data, 32))
        }
        val = address(uint160(raw));
    }

    function _decodeString(bytes memory data) internal pure returns (string memory) {
        if (data.length < 64) return "";
        uint256 offset;
        assembly {
            offset := mload(add(data, 32))
        }
        uint256 strLen;
        assembly {
            strLen := mload(add(add(data, 32), offset))
        }
        if (strLen == 0 || data.length < offset + 32 + strLen) return "";
        bytes memory strBytes = new bytes(strLen);
        for (uint256 i = 0; i < strLen; i++) {
            strBytes[i] = data[offset + 32 + i];
        }
        return string(strBytes);
    }

    // ============ Formatting Helpers ============

    function _formatDecimals(uint256 value, uint256 dec) internal pure returns (string memory) {
        uint256 divisor = 10 ** dec;
        uint256 intPart = value / divisor;
        uint256 fracPart = value % divisor;

        string memory intStr = intPart.toString();
        string memory fracStr = _padLeft(fracPart.toString(), dec);

        return string(abi.encodePacked(intStr, ".", fracStr));
    }

    function _formatWadPercent(uint256 wadValue) internal pure returns (string memory) {
        // WAD fee: 1e18 = 100%. Display as percentage with 4 decimals.
        // e.g. 0.5e18 -> "50.0000%"
        // Convert WAD to basis points first: wadValue * 10000 / 1e18
        uint256 bps = wadValue * 10000 / 1e18;
        uint256 intPart = bps / 100;
        uint256 fracPart = bps % 100;
        return string(abi.encodePacked(intPart.toString(), ".", _padLeft(fracPart.toString(), 2), "%"));
    }

    function _padLeft(string memory s, uint256 width) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        if (b.length >= width) return s;

        uint256 padLen = width - b.length;
        bytes memory padded = new bytes(width);
        for (uint256 i = 0; i < padLen; i++) {
            padded[i] = "0";
        }
        for (uint256 i = 0; i < b.length; i++) {
            padded[padLen + i] = b[i];
        }
        return string(padded);
    }

    function _toAddressString(address addr) internal pure returns (string memory) {
        return string(abi.encodePacked("0x", _toHexBytes(abi.encodePacked(addr))));
    }

    function _toHexString(bytes memory data) internal pure returns (string memory) {
        if (data.length == 0) return "0x";
        uint256 len = data.length > 64 ? 64 : data.length;
        bytes memory result = new bytes(2 + len * 2);
        result[0] = "0";
        result[1] = "x";
        bytes memory hexChars = "0123456789abcdef";
        for (uint256 i = 0; i < len; i++) {
            result[2 + i * 2] = hexChars[uint8(data[i]) >> 4];
            result[3 + i * 2] = hexChars[uint8(data[i]) & 0x0f];
        }
        return string(result);
    }

    function _toHexBytes(bytes memory data) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789abcdef";
        bytes memory result = new bytes(data.length * 2);
        for (uint256 i = 0; i < data.length; i++) {
            result[i * 2] = hexChars[uint8(data[i]) >> 4];
            result[i * 2 + 1] = hexChars[uint8(data[i]) & 0x0f];
        }
        return string(result);
    }

    // ============ Timelock Formatting ============

    function _formatTimelockParams(bytes memory raw, string storage metricName)
        internal
        pure
        returns (bytes memory)
    {
        bytes[] memory results = abi.decode(raw, (bytes[]));
        uint256 duration   = results.length > 0 ? _decodeUint256(results[0]) : 0;
        bool isAbdicated   = results.length > 1 && _decodeUint256(results[1]) != 0;
        return abi.encodePacked(
            metricName, "\n",
            "timelock:  ", _formatDuration(duration), "\n",
            "abdicated: ", isAbdicated ? "true" : "false", "\n"
        );
    }

    function _formatDuration(uint256 secs) internal pure returns (string memory) {
        if (secs == 0) return "0s (no delay)";
        uint256 d  = secs / 86400;
        uint256 h  = (secs % 86400) / 3600;
        uint256 m_ = (secs % 3600) / 60;
        uint256 s_ = secs % 60;
        bytes memory buf = abi.encodePacked(secs.toString(), "s (");
        if (d > 0) buf = abi.encodePacked(buf, d.toString(), "d ");
        buf = abi.encodePacked(buf, h.toString(), "h ", m_.toString(), "m ", s_.toString(), "s)");
        return string(buf);
    }
}
