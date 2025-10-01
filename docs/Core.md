# Core Contracts

## ThyraDiamond

The `ThyraDiamond` contract is the EIP-2535 Diamond Proxy implementation that serves as the core entry point for all ThyraAccount functionality. It routes function calls to appropriate facets while maintaining upgradeability and gas efficiency.

**Key Features:**
- **Two-Tiered Function Dispatch**: Fast path for default facets using immutable storage, slow path using Diamond storage for custom facets
- **Safe Integration**: Stores reference to owning Safe wallet and operates as a Safe module
- **Immutable Facet References**: Default facet addresses stored in immutable variables for gas optimization
- **Factory-Controlled Initialization**: One-time `setSafeWallet()` call during deployment
- **Ether Reception**: Can receive ETH via `receive()` function

**Storage Layout:**
- `safeWallet`: Address of the Safe wallet that owns this Diamond
- `FACTORY`: Immutable address of deploying ThyraFactory
- `I_DIAMOND_CUT_FACET`: Immutable address of DiamondCutFacet implementation
- `I_DIAMOND_LOUPE_FACET`: Immutable address of DiamondLoupeFacet implementation
- `I_EXECUTOR_FACET`: Immutable address of ExecutorFacet implementation
- `I_OWNERSHIP_FACET`: Immutable address of OwnershipFacet implementation

**Fallback Function:**
```solidity
fallback() external payable {
    // Phase 1: Check default facets (immutable storage)
    DefaultFacetType facetType = LibDefaultFacets.getDefaultFacetType(msg.sig);
    
    if (facetType == DiamondCut) facet = I_DIAMOND_CUT_FACET;
    else if (facetType == DiamondLoupe) facet = I_DIAMOND_LOUPE_FACET;
    else if (facetType == Executor) facet = I_EXECUTOR_FACET;
    else if (facetType == Ownership) facet = I_OWNERSHIP_FACET;
    else {
        // Phase 2: Lookup in Diamond storage
        facet = ds.selectorToFacetAndPosition[msg.sig].facetAddress;
    }
    
    // Delegatecall to resolved facet
    delegatecall(facet);
}
```

**Initialization:**
The Diamond is initialized in two phases:
1. **Construction**: Factory deploys Diamond, which adds DiamondCut function
2. **Safe Binding**: Factory calls `setSafeWallet()` to bind to deployed Safe and transfer ownership

## ThyraFactory

The `ThyraFactory` contract handles deployment and configuration of ThyraAccounts (Safe + ThyraDiamond pairs) and SubAccounts with integrated module setup.

**Deployment Capabilities:**
- **ThyraAccount Deployment**: Creates main Safe wallets with ThyraDiamond modules
- **SubAccount Deployment**: Creates Safe wallets with both Diamond and parent Safe as modules
- **Deterministic Addressing**: Uses CREATE2 with nonce-based collision resistance
- **Atomic Setup**: Ensures Safe and Diamond are configured together in a single transaction

**Shared Facet Model:**
All Diamond instances share the same pre-deployed facet implementations:
```solidity
// Immutable shared facet addresses
address public immutable DIAMOND_CUT_FACET;
address public immutable DIAMOND_LOUPE_FACET;
address public immutable EXECUTOR_FACET;
address public immutable OWNERSHIP_FACET;
address public immutable THYRA_REGISTRY;
```

**Nonce Collision Handling:**
The factory tracks deployment nonces per owner set and automatically retries with incremented nonces if CREATE2 address collisions occur:
```solidity
mapping(bytes32 ownersHash => uint256 count) public ownerSafeCount;

function _genNonce(bytes32 _ownersHash, bytes32 _salt) private returns (uint256) {
    return uint256(keccak256(
        abi.encodePacked(_ownersHash, ownerSafeCount[_ownersHash]++, _salt, VERSION)
    ));
}
```

**Deployment Flow:**
1. Generate deterministic salt with nonce
2. Deploy ThyraDiamond with CREATE2 (Factory as temporary owner)
3. Deploy Safe with MultiSend setup (enables Diamond as module)
4. Call `Diamond.setSafeWallet(safe)` to transfer ownership
5. Emit deployment event

**ReentrancyGuard:**
All deployment functions are protected with OpenZeppelin's ReentrancyGuard to prevent reentrancy attacks during the multi-step deployment process.

## ThyraRegistry

The `ThyraRegistry` contract serves as the global configuration and whitelist registry for the entire Thyra ecosystem. It provides centralized validation for executors, fee tokens, and fee configurations.

**Key Functions:**
- **Executor Management**: Global whitelist of approved executor addresses
- **Fee Token Management**: Whitelist and configuration of approved fee payment tokens
- **Validation Service**: Centralized validation logic for task registration
- **Ownership Control**: Owner-only functions for security management

**Storage:**
```solidity
address public owner;
mapping(address => bool) public isExecutorWhitelisted;
mapping(address => bool) public isFeeTokenWhitelisted;

struct FeeConfig {
    uint96 minFee;  // Minimum fee in token's smallest unit
    uint96 maxFee;  // Maximum fee in token's smallest unit
}
mapping(address => FeeConfig) public feeTokenConfigs;
```

**Validation Logic:**
```solidity
function validateTaskRegistration(
    address _executor,
    address _feeToken,
    uint96 _initFee,
    uint96 _maxFee
) external view {
    // Check zero addresses
    require(_executor != address(0) && _feeToken != address(0));
    
    // Check whitelists
    require(isExecutorWhitelisted[_executor]);
    require(isFeeTokenWhitelisted[_feeToken]);
    
    // Validate fee bounds
    FeeConfig memory config = feeTokenConfigs[_feeToken];
    require(_initFee >= config.minFee && _initFee <= config.maxFee);
    require(_maxFee >= config.minFee && _maxFee <= config.maxFee);
    require(_initFee <= _maxFee);
}
```

**Security Model:**
- Only registry owner can modify whitelists and configurations
- Provides emergency response capability (remove malicious actors globally)
- Enforces consistent fee standards across all ThyraAccount instances

## ExecutorFacet

The `ExecutorFacet` contract is the core execution engine for ThyraAccount. It manages task registration, Merkle proof validation, and operation execution through the Safe module system.

**Task Management System:**
- **Task Registration**: Safe owners register Merkle trees representing operation batches
- **Status Management**: Tasks transition through INACTIVE → ACTIVE → COMPLETED/CANCELLED
- **Executor Authorization**: Each task has a designated executor from the global whitelist
- **Merkle Validation**: Operations validated using OpenZeppelin's MerkleProof library

**Optimized Task Storage:**
Tasks use a highly optimized 2-slot storage layout:
```solidity
struct Task {
    uint256 slot1; // executor(160) + executedBitmap(88) + status(8)
    uint256 slot2; // feeToken(160) + initFee(48) + maxFee(48)
}
mapping(bytes32 merkleRoot => Task) tasks;
```

**Execution Flow:**
```solidity
function executeTransaction(
    bytes32 _merkleRoot,
    Operation calldata _operation,
    bytes32[] calldata _merkleProof
) external returns (bytes memory returnData) {
    // Phase 1: Task State Validation
    _validateTaskState(slot1);
    
    // Phase 2: Cryptographic Validation
    _validateMerkleProof(_merkleRoot, _operation, _merkleProof);
    
    // Phase 3: Operation Constraints Validation
    _validateOperationConstraints(slot1, _operation);
    
    // Phase 4: Execute via Safe Module
    returnData = _executeOperation(_operation);
    
    // Phase 5: Update Execution State
    _updateExecutionState(_merkleRoot, slot1, _operation.operationId);
    
    emit ExecutionSuccess(...);
}
```

**Validation Phases:**

1. **Task State Validation**:
   - Task must exist (`slot1 != 0`)
   - Caller must be task's executor (`msg.sender == executor`)
   - Task must be ACTIVE (`status == 1`)

2. **Cryptographic Validation**:
   ```solidity
   bytes32 leafHash = keccak256(abi.encode(_operation));
   require(MerkleProof.verify(_merkleProof, _merkleRoot, leafHash));
   ```

3. **Operation Constraints**:
   - `operationId < 88` (bitmap size limit)
   - `callType == CALL` (DELEGATECALL not supported)
   - `block.timestamp >= startTime && block.timestamp <= endTime`
   - `tx.gasprice <= maxGasPrice`
   - If `!isRepeatable`: check bit not set in `executedOperationsBitmap`

**Safe Module Execution:**
```solidity
function _executeOperation(Operation memory _operation) internal returns (bytes memory) {
    address safeWallet = ThyraDiamond(payable(address(this))).safeWallet();
    
    (bool success, bytes memory result) = 
        IModuleManager(safeWallet).execTransactionFromModuleReturnData(
            _operation.target,
            _operation.value,
            _operation.callData,
            Enum.Operation.Call
        );
    
    require(success, "Execution failed");
    return result;
}
```

**ThyraRegistry Integration:**
ExecutorFacet is deployed with an immutable ThyraRegistry address:
```solidity
address public immutable THYRA_REGISTRY;

constructor(address _thyraRegistry) {
    THYRA_REGISTRY = _thyraRegistry;
}
```

This ensures all ExecutorFacet instances validate against the same global registry.

## DiamondCutFacet

The `DiamondCutFacet` contract provides the core EIP-2535 upgradeability functionality. It allows the Diamond owner (Safe wallet) to add, replace, or remove functions.

**Key Function:**
```solidity
function diamondCut(
    LibDiamond.FacetCut[] calldata _diamondCut,
    address _init,
    bytes calldata _calldata
) external {
    LibDiamond.enforceIsContractOwner();
    LibDiamond.diamondCut(_diamondCut, _init, _calldata);
}
```

**FacetCut Structure:**
```solidity
struct FacetCut {
    address facetAddress;       // Target facet contract
    FacetCutAction action;      // Add(0), Replace(1), Remove(2)
    bytes4[] functionSelectors; // Function selectors to modify
}
```

**Upgrade Patterns:**

1. **Add New Functions**:
   ```solidity
   FacetCut[] memory cut = new FacetCut[](1);
   cut[0] = FacetCut({
       facetAddress: newFacet,
       action: FacetCutAction.Add,
       functionSelectors: [selector1, selector2]
   });
   diamondCut(cut, address(0), "");
   ```

2. **Replace Existing Functions**:
   ```solidity
   cut[0] = FacetCut({
       facetAddress: upgradedFacet,
       action: FacetCutAction.Replace,
       functionSelectors: [existingSelector]
   });
   ```

3. **Remove Functions**:
   ```solidity
   cut[0] = FacetCut({
       facetAddress: address(0),
       action: FacetCutAction.Remove,
       functionSelectors: [selectorToRemove]
   });
   ```

**Security:**
- Only Diamond owner (Safe wallet) can execute diamondCut
- Validates facet addresses contain code
- Prevents duplicate function selectors
- Supports initialization call after upgrade via `_init` delegatecall

**Default Facet Persistence:**
Upgrading via DiamondCut affects the Diamond storage mapping but does not affect the fast path immutable facet references. This means:
- Default facets remain gas-optimized even after upgrades
- Custom facets can be added without degrading default facet performance
- Default facets can be replaced in Diamond storage as a fallback

## DiamondLoupeFacet

The `DiamondLoupeFacet` contract provides introspection capabilities for the Diamond proxy, implementing the EIP-2535 Loupe functions.

**Introspection Functions:**

```solidity
// Get all facets and their function selectors
function facets() external view returns (Facet[] memory);

// Get all function selectors for a specific facet
function facetFunctionSelectors(address _facet) external view 
    returns (bytes4[] memory);

// Get all facet addresses
function facetAddresses() external view returns (address[] memory);

// Get facet address for a specific function selector
function facetAddress(bytes4 _functionSelector) external view 
    returns (address);
```

**Use Cases:**
- **Verification**: Confirm function selector routing after upgrades
- **Documentation**: Generate on-chain function mappings for frontends
- **Debugging**: Diagnose function dispatch issues
- **Auditing**: Verify Diamond configuration matches expected state

**ERC-165 Support:**
```solidity
function supportsInterface(bytes4 _interfaceId) external view 
    returns (bool) {
    LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
    return ds.supportedInterfaces[_interfaceId];
}
```

## OwnershipFacet

The `OwnershipFacet` contract manages Diamond ownership and provides ERC-173 compliance.

**Key Functions:**
```solidity
// Get current owner
function owner() external view returns (address);

// Transfer ownership (only owner)
function transferOwnership(address _newOwner) external;
```

**Ownership Transfer:**
```solidity
function transferOwnership(address _newOwner) external {
    LibDiamond.enforceIsContractOwner();
    LibDiamond.setContractOwner(_newOwner);
}
```

**Events:**
```solidity
event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
```

**Integration with Safe:**
Initially, the Factory owns the Diamond during deployment. The Factory then transfers ownership to the Safe wallet via `ThyraDiamond.setSafeWallet()`, which internally calls `LibDiamond.setContractOwner()`.

## Libraries

### LibDiamond

The `LibDiamond` library implements the core EIP-2535 Diamond storage pattern and management functions.

**Diamond Storage:**
```solidity
bytes32 constant DIAMOND_STORAGE_POSITION = 
    keccak256("diamond.standard.diamond.storage");

struct DiamondStorage {
    mapping(bytes4 => FacetAddressAndPosition) selectorToFacetAndPosition;
    mapping(address => FacetFunctionSelectors) facetFunctionSelectors;
    address[] facetAddresses;
    mapping(bytes4 => bool) supportedInterfaces;
    address contractOwner;
}
```

**Key Functions:**
- `diamondStorage()`: Access Diamond storage using storage pointer
- `setContractOwner()`: Update Diamond owner
- `enforceIsContractOwner()`: Revert if caller is not owner
- `diamondCut()`: Execute facet modifications
- `addFunctions()`, `replaceFunctions()`, `removeFunctions()`: Facet management

**Storage Pattern:**
Uses the "Diamond Storage" pattern to avoid storage slot collisions between facets:
```solidity
function diamondStorage() internal pure returns (DiamondStorage storage ds) {
    bytes32 position = DIAMOND_STORAGE_POSITION;
    assembly {
        ds.slot := position
    }
}
```

### LibDefaultFacets

The `LibDefaultFacets` library provides fast path function selector mapping for default facets.

**Default Facet Types:**
```solidity
enum DefaultFacetType {
    None,
    DiamondCut,
    DiamondLoupe,
    Executor,
    Ownership
}
```

**Function Selector Mapping:**
```solidity
function getDefaultFacetType(bytes4 selector) internal pure 
    returns (DefaultFacetType) {
    
    // DiamondCutFacet selectors
    if (selector == IDiamondCut.diamondCut.selector) 
        return DefaultFacetType.DiamondCut;
    
    // DiamondLoupeFacet selectors
    if (selector == IDiamondLoupe.facets.selector ||
        selector == IDiamondLoupe.facetFunctionSelectors.selector ||
        selector == IDiamondLoupe.facetAddresses.selector ||
        selector == IDiamondLoupe.facetAddress.selector)
        return DefaultFacetType.DiamondLoupe;
    
    // ExecutorFacet selectors
    if (selector == IExecutorFacet.registerTask.selector ||
        selector == IExecutorFacet.executeTransaction.selector ||
        ...)
        return DefaultFacetType.Executor;
    
    // OwnershipFacet selectors
    if (selector == IERC173.owner.selector ||
        selector == IERC173.transferOwnership.selector)
        return DefaultFacetType.Ownership;
    
    return DefaultFacetType.None;
}
```

**Gas Optimization:**
This approach eliminates storage reads for default facets, reducing gas costs from ~2,600 to ~2,100 per call.

### SafeHelpers

The `SafeHelpers` library provides utilities for Safe wallet interaction and MultiSend transaction packing.

**Key Functions:**

```solidity
// Pack multiple transactions for Safe MultiSend
function packMultisendTxns(Executable[] memory _txns) 
    internal pure returns (bytes memory);

// Operation enum conversion
function parseOperationEnum(CallType _operation) 
    internal pure returns (Enum.Operation);
```

**MultiSend Packing:**
```solidity
struct Executable {
    CallType callType;
    address target;
    uint256 value;
    bytes data;
}

function packMultisendTxns(Executable[] memory _txns) 
    internal pure returns (bytes memory packedTxns) {
    
    for (uint256 i = 0; i < _txns.length; i++) {
        uint8 operation = _txns[i].callType == CallType.CALL ? 0 : 1;
        bytes memory encoded = abi.encodePacked(
            operation,
            _txns[i].target,
            _txns[i].value,
            _txns[i].data.length,
            _txns[i].data
        );
        packedTxns = abi.encodePacked(packedTxns, encoded);
    }
}
```

**Use Cases:**
- Packing module enable transactions during Safe setup
- Preparing batched operations for execution
- Converting between CallType and Safe's Operation enum

### BigMathMinified

The `BigMathMinified` library provides compressed number representation for storing fees in reduced bit space.

**Compression Format:**
```
BigNumber (48 bits) = significand (40 bits) + exponent (8 bits)
Value = significand × 10^exponent
```

**Key Functions:**
```solidity
// Convert uint96 to compressed 48-bit BigNumber
function toBigNumber(
    uint256 value,
    uint256 significandBits,
    uint256 exponentBits,
    bool roundUp
) internal pure returns (uint256);

// Convert BigNumber back to normal uint256
function fromBigNumber(
    uint256 bigNumber,
    uint256 exponentBits,
    uint256 exponentMask
) internal pure returns (uint256);
```

**Example Usage:**
```solidity
// Store 1,000,000 USDC (6 decimals) as BigNumber
uint96 fee = 1_000_000_000_000; // 1M USDC in smallest unit
uint256 compressed = BigMathMinified.toBigNumber(fee, 40, 8, false);
// compressed uses only 48 bits instead of 96 bits

// Retrieve original value
uint256 originalFee = BigMathMinified.fromBigNumber(compressed, 8, 0xFF);
```

**Storage Savings:**
- Task.slot2 stores two fees (initFee, maxFee) in 96 bits total
- Without compression: would require 192 bits (2 × uint96)
- Savings: 50% reduction in fee storage costs

### TypeHashHelper

The `TypeHashHelper` library provides EIP-712 structured data hashing utilities for signature validation and transaction structuring.

**Key Functions:**
```solidity
// Build execution params hash for EIP-712 signing
function buildExecutionParamsHash(
    ExecutionParams memory params
) internal pure returns (bytes32);

// Type hash constants
function EXECUTION_PARAMS_TYPEHASH() internal pure returns (bytes32);
```

**Use Cases:**
- Future signature-based operation authorization
- Off-chain signature verification
- EIP-712 structured data hashing for operations

## Security Considerations

### Access Control
- **DiamondCutFacet**: Only Safe wallet (owner) can modify functions
- **ExecutorFacet.registerTask()**: Only Safe wallet can register tasks
- **ExecutorFacet.executeTransaction()**: Only whitelisted executor can execute
- **ThyraRegistry**: Only registry owner can modify whitelists

### Upgradeability
- **Diamond Proxy**: Upgradeability controlled by Safe multi-sig
- **Immutable Facets**: Default facet addresses cannot change (gas optimization)
- **Diamond Storage Fallback**: Custom facets can override defaults via DiamondCut
- **Registry Immutability**: ThyraRegistry address is immutable per ExecutorFacet deployment

### Validation
- **Multi-Layer Checks**: Task state → Merkle proof → operation constraints → execution
- **Registry Validation**: Centralized validation prevents unauthorized executors/tokens
- **Bitmap Protection**: Prevents double-execution of non-repeatable operations
- **Time Window Enforcement**: Blocks operations outside allowed time ranges
- **Gas Price Caps**: Protects against MEV and high gas environments

### Storage Safety
- **Diamond Storage Pattern**: Prevents storage collisions between facets
- **Immutable References**: Factory and registry addresses cannot change
- **One-Time Initialization**: `setSafeWallet()` can only be called once
- **Packed Structures**: Optimized storage layout reduces attack surface

---

The core contracts work together to provide a secure, efficient, and flexible platform for advanced Smart Contract Account operations while maintaining upgradeability and compatibility with Gnosis Safe infrastructure.


