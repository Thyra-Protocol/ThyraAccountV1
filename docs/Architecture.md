# Architecture and Transaction Flows

## ThyraAccount Task Registration

To register a task via ThyraAccount, the Safe wallet owners call the `registerTask()` function through the ThyraDiamond proxy. This establishes a Merkle tree-based authorization for a batch of operations.

1. Safe wallet (owner) initiates `registerTask()` call to ThyraDiamond
2. ThyraDiamond delegates call to ExecutorFacet via Diamond fallback
3. ExecutorFacet validates parameters against ThyraRegistry
4. Task stored with ACTIVE status and merkleRoot as key
5. ExecutedOperationsBitmap initialized to track non-repeatable operations

This creates a pre-authorized operation set that can be executed independently by the designated executor.

![ThyraAccount Task Registration Flow](https://raw.githubusercontent.com/thyra-fi/ThyraAccount/main/docs/images/task-registration-flow.png)

## Operation Execution via ExecutorFacet

For an executor to execute a registered operation, they call `executeTransaction()` with the operation data and Merkle proof. The system performs comprehensive validation before execution.

### Standard Operation Execution

1. Executor calls `executeTransaction()` on ThyraDiamond
2. ThyraDiamond delegates to ExecutorFacet
3. ExecutorFacet validates in phases:
   - **Phase 1: Task State** - Verify task exists, is active, and caller is authorized executor
   - **Phase 2: Cryptographic** - Verify Merkle proof using OpenZeppelin's MerkleProof library
   - **Phase 3: Constraints** - Check operationId bounds, time window, gas price, repeatability
4. ExecutorFacet calls Safe's `execTransactionFromModuleReturnData()`
5. Safe executes the transaction with Diamond as authorized module
6. If non-repeatable, set bit in executedOperationsBitmap
7. Emit ExecutionSuccess event with operation details

### Validation Flow Detail

```
┌─────────────────────────────────────────┐
│         Executor calls                  │
│    executeTransaction()                 │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│  Phase 1: Task State Validation         │
│  - Task exists (slot1 != 0)            │
│  - Caller == task.executor              │
│  - Task status == ACTIVE                │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│  Phase 2: Cryptographic Validation      │
│  - Compute leaf = keccak256(operation)  │
│  - MerkleProof.verify(proof, root, leaf)│
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│  Phase 3: Operation Constraints         │
│  - operationId < 88                     │
│  - callType == CALL                     │
│  - block.timestamp ∈ [start, end]       │
│  - tx.gasprice <= maxGasPrice           │
│  - If !repeatable: check bitmap         │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│  Execute via Safe Module                │
│  Safe.execTransactionFromModuleReturnData│
│  (target, value, data, Call)            │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│  Update State (if non-repeatable)       │
│  Set bit in executedOperationsBitmap    │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│  Emit ExecutionSuccess Event            │
└─────────────────────────────────────────┘
```

![Operation Execution Flow](https://raw.githubusercontent.com/thyra-fi/ThyraAccount/main/docs/images/operation-execution-flow.png)

## Diamond Function Dispatch

ThyraDiamond implements a two-tiered function lookup system for gas optimization while maintaining EIP-2535 upgradeability.

### Fast Path (Default Facets)

1. Call received by Diamond fallback
2. `LibDefaultFacets.getDefaultFacetType(msg.sig)` checks function selector
3. If default facet (DiamondCut, DiamondLoupe, Executor, Ownership):
   - Load facet address from immutable storage
   - Direct delegatecall to facet
4. If not default facet, proceed to slow path

### Slow Path (Diamond Storage)

1. Load DiamondStorage from Diamond storage position
2. Lookup `selectorToFacetAndPosition[msg.sig]`
3. Get facet address from mapping
4. Delegatecall to resolved facet address

### Optimization Benefits

- **Default Facets**: ~2,100 gas for function dispatch (immutable storage read)
- **Custom Facets**: ~2,600 gas for function dispatch (storage read)
- **Upgradeability**: Custom facets can be added/replaced without affecting default fast path

```
┌─────────────────────────────────────────┐
│     Function call to Diamond            │
│     (e.g., executeTransaction)          │
└────────────────┬────────────────────────┘
                 │
                 ▼
         ┌───────────────┐
         │   Fallback    │
         └───────┬───────┘
                 │
                 ▼
         ┌───────────────────────┐
         │ getDefaultFacetType() │
         └───────┬───────────────┘
                 │
        ┌────────┴────────┐
        │                 │
        ▼                 ▼
┌──────────────┐  ┌──────────────┐
│  Fast Path   │  │  Slow Path   │
│  (Immutable) │  │  (Storage)   │
└──────┬───────┘  └──────┬───────┘
       │                 │
       │                 ▼
       │         ┌───────────────┐
       │         │ Load Diamond  │
       │         │   Storage     │
       │         └───────┬───────┘
       │                 │
       │                 ▼
       │         ┌───────────────┐
       │         │ Lookup Facet  │
       │         │   Address     │
       │         └───────┬───────┘
       │                 │
       └────────┬────────┘
                │
                ▼
        ┌───────────────┐
        │  Delegatecall  │
        │   to Facet     │
        └────────────────┘
```

![Diamond Dispatch Flow](https://raw.githubusercontent.com/thyra-fi/ThyraAccount/main/docs/images/diamond-dispatch-flow.png)

## Account Deployment Flow

ThyraFactory handles atomic deployment and configuration of Safe wallets with integrated ThyraDiamond modules.

### ThyraAccount Deployment (Main Account)

1. Call `deployThyraAccount(owners, threshold, salt)`
2. Factory deploys ThyraDiamond with CREATE2:
   - Factory temporarily owns Diamond
   - Diamond constructor adds DiamondCut function
   - Immutable default facet addresses stored
3. Factory deploys Safe with MultiSend setup:
   - Safe setup calls MultiSend
   - MultiSend enables Diamond as module
   - Safe deployed with configured owners and threshold
4. Factory calls `Diamond.setSafeWallet(safeAddress)`:
   - Transfers Diamond ownership to Safe
   - Initializes Safe wallet reference
5. Emit ThyraAccountDeployed event

### SubAccount Deployment

1. Call `deploySubAccount(owners, threshold, parentSafe, salt)`
2. Factory deploys ThyraDiamond (same as main account)
3. Factory deploys Safe with MultiSend setup:
   - Safe setup calls MultiSend twice:
     - Enable Diamond as module
     - Enable parentSafe as module
   - Sub-account can be controlled by both owners and parent Safe
4. Factory calls `Diamond.setSafeWallet(subAccountAddress)`
5. Emit ThyraSubAccountDeployed event

### Nonce Collision Handling

Both Safe and Diamond deployments use CREATE2 with nonce-based collision resistance:

```solidity
// Generate unique salt with nonce
salt = keccak256(abi.encodePacked(ownersHash, nonce, userSalt, VERSION))

// Check for collision
if (predictedAddress.code.length > 0) {
    nonce++;  // Increment and retry
    continue;
}

// Deploy with collision-free salt
Deploy(salt, creationCode)
```

This ensures reliable deterministic addresses while handling edge cases where addresses collide.

```
┌─────────────────────────────────────────┐
│  deployThyraAccount(owners, threshold)  │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│  Deploy ThyraDiamond (CREATE2)          │
│  - Factory as temporary owner           │
│  - Immutable facet addresses            │
│  - DiamondCut function added            │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│  Deploy Safe with MultiSend Setup       │
│  - Configure owners and threshold       │
│  - Enable Diamond as module             │
│  - Set fallback handler                 │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│  Diamond.setSafeWallet(safe)            │
│  - Transfer ownership to Safe           │
│  - Initialize Safe reference            │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│  Emit ThyraAccountDeployed              │
│  (safe, diamond, owners, threshold)     │
└─────────────────────────────────────────┘
```

![Account Deployment Flow](https://raw.githubusercontent.com/thyra-fi/ThyraAccount/main/docs/images/account-deployment-flow.png)

## Task Status Management

Tasks can transition through different states based on owner and executor actions.

### Status Transition Diagram

```
                    ┌──────────────┐
                    │  INACTIVE    │  (Default state)
                    └──────┬───────┘
                           │
                           │ registerTask() (Owner)
                           ▼
                    ┌──────────────┐
            ┌──────▶│   ACTIVE     │◀──────┐
            │       └──────┬───────┘       │
            │              │               │
            │              │               │
   Owner:   │              │               │  Owner/Executor:
   cancel() │              │               │  cancel()
            │              │               │
            │              ▼               │
            │       ┌──────────────┐       │
            │       │  COMPLETED   │       │
            │       └──────────────┘       │
            │                              │
            ▼                              │
     ┌──────────────┐                     │
     │  CANCELLED   │◀────────────────────┘
     └──────────────┘
```

### Status Transition Rules

| Current Status | New Status | Who Can Change | Condition |
|---------------|-----------|----------------|-----------|
| INACTIVE | ACTIVE | Owner | Via registerTask() |
| ACTIVE | COMPLETED | Executor | Any time |
| ACTIVE | CANCELLED | Owner or Executor | Any time |
| COMPLETED | - | - | Terminal state |
| CANCELLED | - | - | Terminal state |

### Permission Matrix

| Role | Can Register | Can Execute | Can Complete | Can Cancel |
|------|-------------|-------------|--------------|------------|
| Owner (Safe) | ✅ | ❌ | ❌ | ✅ (if not COMPLETED) |
| Executor | ❌ | ✅ (if ACTIVE) | ✅ | ✅ (if ACTIVE) |
| Other | ❌ | ❌ | ❌ | ❌ |

## Registry-Based Authorization

ThyraRegistry provides centralized validation for the entire ecosystem.

### Registration Flow

1. **Executor Whitelist**:
   ```
   Registry Owner → setExecutor(address, true)
   ```

2. **Fee Token Whitelist**:
   ```
   Registry Owner → setFeeToken(token, true)
   Registry Owner → setFeeConfig(token, minFee, maxFee)
   ```

3. **Task Registration Validation**:
   ```
   ExecutorFacet → Registry.validateTaskRegistration()
   - Check executor is whitelisted
   - Check fee token is whitelisted
   - Validate fee amounts within bounds
   ```

### Global Configuration Benefits

- **Rapid Response**: Disable malicious executors globally with single transaction
- **Fee Standardization**: Enforce consistent fee ranges across all tasks
- **Upgradeable Validation**: Can extend validation logic without upgrading facets
- **Emergency Controls**: Pause system by removing all executors from whitelist

```
┌─────────────────────────────────────────┐
│      ThyraRegistry (Global Config)      │
│                                         │
│  ┌─────────────────────────────────┐   │
│  │  Executor Whitelist             │   │
│  │  isExecutorWhitelisted[addr]    │   │
│  └─────────────────────────────────┘   │
│                                         │
│  ┌─────────────────────────────────┐   │
│  │  Fee Token Whitelist            │   │
│  │  isFeeTokenWhitelisted[token]   │   │
│  └─────────────────────────────────┘   │
│                                         │
│  ┌─────────────────────────────────┐   │
│  │  Fee Configurations             │   │
│  │  feeTokenConfigs[token]         │   │
│  │  { minFee, maxFee }             │   │
│  └─────────────────────────────────┘   │
└────────────────┬────────────────────────┘
                 │
                 │ validateTaskRegistration()
                 │
                 ▼
┌─────────────────────────────────────────┐
│      ExecutorFacet (All Instances)      │
│                                         │
│  registerTask() validates via Registry  │
│  executeTransaction() checks executor   │
└─────────────────────────────────────────┘
```

## Gas Optimization Strategies

### Shared Facet Implementations

All ThyraDiamond instances share the same facet deployments:

```
┌──────────────┐   ┌──────────────┐   ┌──────────────┐
│  Diamond 1   │   │  Diamond 2   │   │  Diamond 3   │
└──────┬───────┘   └──────┬───────┘   └──────┬───────┘
       │                  │                  │
       └──────────────────┼──────────────────┘
                          │
                          │ delegatecall
                          ▼
              ┌──────────────────────┐
              │  Shared Facets       │
              │  - DiamondCutFacet   │
              │  - DiamondLoupeFacet │
              │  - ExecutorFacet     │
              │  - OwnershipFacet    │
              └──────────────────────┘
```

**Benefits**:
- One-time deployment cost for facets
- Consistent behavior across all instances
- Reduced blockchain state bloat

### Bitmap Execution Tracking

88-bit bitmap efficiently tracks non-repeatable operation execution:

```
Operation IDs:    0  1  2  3  ... 87
Bitmap:          [0][1][0][0] ... [1]
Storage:         Single uint88 (11 bytes)

Alternative (mapping):
mapping(uint32 => bool) executed;
Cost per operation: 20,000 gas (SSTORE)

Bitmap cost: 5,000 gas (SSTORE to flip bit)
Savings: 15,000 gas per non-repeatable operation
```

### Compressed Fee Storage

BigMathMinified reduces fee storage from 96 bits to 48 bits per fee:

```
Standard uint96:     96 bits per fee × 2 = 192 bits
BigNumber (40,8):    48 bits per fee × 2 = 96 bits
Savings:             96 bits = 50% reduction

Format: significand (40 bits) + exponent (8 bits)
Range: 0 to ~1.1e15 (sufficient for most tokens)
Precision: ~1e-6 relative error
```

### Fast Path Function Dispatch

Default facets use immutable storage instead of Diamond storage:

```
Gas Cost Comparison:
- Immutable storage load: ~100 gas
- Diamond storage lookup: ~600 gas
- Savings per call: ~500 gas

For ExecutorFacet (high frequency):
- 1000 executions/day × 500 gas = 500,000 gas/day saved
```

## Security Validation Layers

### Multi-Layer Defense

```
Layer 1: Safe Multi-Sig
└─> Owners must approve registerTask()

    Layer 2: ThyraRegistry Whitelist
    └─> Executor must be globally approved
    └─> Fee token must be whitelisted
    └─> Fees must be within bounds

        Layer 3: Merkle Proof
        └─> Operation must cryptographically prove inclusion

            Layer 4: Operation Constraints
            └─> Time window validation
            └─> Gas price validation
            └─> Repeatability check

                Layer 5: Safe Module Execution
                └─> Final execution through Safe's proven infrastructure
```

### Attack Surface Analysis

| Attack Vector | Mitigation |
|--------------|------------|
| Unauthorized Execution | Executor whitelist + msg.sender check |
| Replay Attacks | 88-bit execution bitmap for non-repeatable ops |
| MEV Front-Running | Gas price caps per operation |
| Time-Based Attacks | Start/end timestamp enforcement |
| Merkle Proof Forgery | OpenZeppelin's battle-tested MerkleProof.sol |
| Diamond Upgrade Attacks | Only Safe (owner) can call DiamondCut |
| Module Manipulation | Safe owners control module list |
| Fee Manipulation | ThyraRegistry enforces global min/max bounds |

---

The architecture emphasizes security, efficiency, and flexibility while maintaining compatibility with existing Safe infrastructure and DeFi protocols. The combination of EIP-2535 Diamond pattern, Merkle tree authorization, and Safe integration creates a powerful foundation for advanced smart contract account operations.


