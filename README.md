# ThyraAccount

[![License: LGPL-3.0](https://img.shields.io/badge/License-LGPL--3.0-blue.svg)](https://www.gnu.org/licenses/lgpl-3.0)
[![Solidity: 0.8.17+](https://img.shields.io/badge/Solidity-0.8.17+-blue)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg)](https://getfoundry.sh/)

ThyraAccount is a next-generation Smart Contract Account system combining Gnosis Safe security with advanced execution capabilities through the EIP-2535 Diamond Proxy pattern. It enables pre-authorized, batched transaction execution via a Merkle tree-based task system.

## Key Features

- **Merkle Tree-Based Authorization**: Cryptographically commit to operation batches with on-chain proof verification.
- **Diamond Proxy Architecture (EIP-2535)**: Modular, upgradeable, and unlimited contract size.
- **Gnosis Safe Integration**: Built on proven Safe v1.5+ multi-sig infrastructure.
- **Advanced Execution Controls**: Time-bounded operations, gas price protection, and authorized executors.

## Architecture Overview

```
┌─────────────────────────────────────────────┐
│         Safe Wallet (Multi-Sig)             │
│              Owner & Control                │
└────────────────────┬────────────────────────┘
                     │
                     ▼
         ┌───────────────────────┐
         │   ThyraDiamond        │
         │   (EIP-2535 Proxy)    │
         └───────────┬───────────┘
                     │
            ┌────────┴────────┐
            │                 │
            ▼                 ▼
    ┌──────────────┐  ┌──────────────┐
    │ ExecutorFacet│  │ Other Facets │
    │  (Tasks &    │  │  (Ownership, │
    │  Execution)  │  │   Diamond)   │
    └──────┬───────┘  └──────────────┘
           │
           ▼
    ┌──────────────┐
    │ThyraRegistry │
    │  (Global     │
    │  Whitelist)  │
    └──────────────┘
```

## Quick Start

### Installation

```bash
# Clone the repository
git clone https://github.com/Thyra-Protocol/ThyraAccountV1.git
cd ThyraAccountV1

# Install dependencies
forge install
```

### Build

```bash
forge build
```

### Test

```bash
# Run all tests
forge test

# Run with gas report
forge test --gas-report
```

## Documentation

For more detailed information, please refer to the `docs/` directory:
- 📚 **[Introduction](./docs/Introduction.md)**
- 🏗️ **[Architecture](./docs/Architecture.md)**
- ⚙️ **[Core Contracts](./docs/Core.md)**

## License

This project is licensed under the LGPL-3.0 License.
