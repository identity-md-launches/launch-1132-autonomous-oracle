# AutonomoUs oracle (ORACLE)

A fixed-supply ERC-20 token for an IdentityMD custom token launch on Ethereum (chain id 1).

| Parameter | Value |
|---|---|
| Solidity contract | `OracleToken` (`src/OracleToken.sol`) |
| `name()` | `AutonomoUs oracle` |
| `symbol()` | `ORACLE` |
| `decimals()` | `18` |
| `totalSupply()` | `1000000000000000000000000000` (1,000,000,000 × 10^18) |
| Constructor arguments | none |
| Minted to | `msg.sender` of the constructor, once, in full |
| Owner / admin | none |
| Mint after deployment | impossible (no mint path; `totalSupply()` is a compile-time constant) |
| Burn | none (no burn path either) |
| Transfer fee, tax, reflection, blocklist, pause, hooks | none |
| Proxy / upgradeability / delegatecall / selfdestruct | none |
| Compiler | solc 0.8.26, optimizer on (200 runs), `bytecode_hash = "none"`, `cbor_metadata = false` |

## What the token does

`OracleToken` is a plain, self-contained ERC-20 (EIP-20 with the metadata extension) with ERC-6093
style custom errors:

- `transfer` and `transferFrom` move exactly the amount requested. There is no fee, burn or
  reflection on any path, so every launch flow (factory → distributor, distributor → claimant,
  factory → pool, trader ↔ pool) moves exactly what it says.
- `approve` sets the allowance outright. `transferFrom` decreases a finite allowance and treats
  `type(uint256).max` as unlimited (it is not decreased).
- Transfers to the zero address revert (`ERC20InvalidReceiver`); approvals of the zero spender
  revert (`ERC20InvalidSpender`); overspending reverts with `ERC20InsufficientBalance` or
  `ERC20InsufficientAllowance`.
- The contract has no `receive`/`fallback`: ETH sent to it and unknown selectors revert.
- The contract uses no library and no external call: there is nothing to link, and the runtime
  contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` (asserted by a test).

## Launch flow (IdentityMD custom token launch)

The launch is decided by the network and is not configurable here:

- `ProjectFactory.launchCustom` deploys `OracleToken` from its creation code through CREATE2. The
  factory is `msg.sender` of the constructor and therefore receives the whole supply.
- The factory forwards 10% of the supply to the launch's MerkleDistributor (swarm share), seeds the
  Uniswap v4 pool single-sided with `economics.poolBps` = 80% of the supply, and sends the remaining
  10% to `economics.remainderTo` (`0x70bcbde387539d95ffe6d43edbf7c6aa2da87a09`).
- Pool: paired with IMD (`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, 18 decimals), fee 12500
  (1.25%), tick spacing 60; the deployer derives the opening price from
  `economics.initialMarketCapWei` = 2,500 IMD for the whole supply.
- The manifest (`launch.json`) is written by the manifest step after acceptance, not by this
  repository. For reference, its token entry is: `contract: "OracleToken"`, `name: "AutonomoUs
  oracle"`, `symbol: "ORACLE"`, `decimals: 18`, `constructorArgs: []`,
  `totalSupply: "1000000000000000000000000000"`.

No application contracts are part of this launch (`contracts: []`).

Because the token exempts nobody and taxes nobody, it needs none of the optional launch constructor
arguments (`$factory`, `$poolManager`, `$launchNumber`) and never calls `distributorOf`.

## Assumptions

- The requester wants a plain token: no owner, no mint, no burn, no tax, no vesting, no governance.
  The brief names only the name, symbol and supply, so nothing else was added.
- The supply is stated in minor units with 18 decimals and is final at construction. Nothing in the
  contract can change it later, in either direction.
- "All minted once to the deployer" means the address that executes `new OracleToken()`. At launch
  that is the factory; in the standalone script it is the broadcasting account.
- The Solidity identifier (`OracleToken`, 11 characters) is what the manifest records, not the
  display name; the display name is returned by `name()`.

## Deployment parameters

The constructor takes no arguments. There is nothing to configure before or after deployment.

### Launch deployment (the normal path)

Handled entirely by the IdentityMD deployer from the bytecode built by `forge build` with this
`foundry.toml`. Do not change the compiler settings: the launch compares the deployed bytes with
the metadata hash stripped (`bytecode_hash = "none"`).

### Standalone deployment (reviewable, not used by the launch)

`script/DeployOracleToken.s.sol` deploys the token with `new OracleToken()` from the broadcasting
account, which then holds the whole supply. It reads nothing from the environment. For a dry run:

```bash
forge script script/DeployOracleToken.s.sol --rpc-url <RPC> --sender <DEPLOYER>
```

Add `--broadcast` and a signer only when a deployment is actually intended. This assignment does
not authorise transactions and does not hold keys.

## After launch

Nothing to set. The token has no owner, no setter and no configurable value. There are no
operational responsibilities beyond the ordinary ones for a public ERC-20:

- Verify the source on the block explorer after deployment (`forge verify-contract`, with the same
  compiler settings as `foundry.toml`).
- Publish the token address, name, symbol and decimals to holders and integrators.
- Anyone who receives tokens is responsible for their own keys and allowances; no one can recover,
  freeze or move a holder's balance.

## Security notes and trust assumptions

- **No privileged roles.** No address can mint, burn, pause, freeze, block, seize or upgrade. The
  deployer is an ordinary holder once the constructor returns.
- **Fixed supply.** `totalSupply()` returns a constant; the sum of balances always equals it (fuzz
  tested). Arithmetic in `_transfer` is unchecked only after the balance check that makes it safe.
- **No external calls, no reentrancy surface.** The contract never calls another contract.
- **Allowance race.** Like every standard ERC-20, `approve` overwrites; a spender front-running an
  allowance change can spend old + new. Set the allowance to zero first when changing a non-zero
  one, or approve only what is needed.
- **Tokens sent to the contract itself** (`transfer(address(token), x)`) are stuck, as with any
  ERC-20 without a rescue function. There is deliberately no rescue function, since that would be a
  privileged power.
- Tests passing are not an audit. Any work that holds other people's funds needs an independent
  adversarial review before release.

Tooling run here: `forge build`, `forge test` (unit + fuzz, 256 runs), `forge fmt --check`. Slither
and Mythril were not available in this environment and were not run.

## Layout

```
foundry.toml                      compiler pins and build settings
remappings.txt                    forge-std/ → lib/forge-std/src/
lib/forge-std/                    forge-std v1.11.0, vendored as plain files (no submodule)
src/OracleToken.sol               the token
src/interfaces/IERC20.sol         the ERC-20 interface it implements
script/DeployOracleToken.s.sol    standalone deploy script (run() → deploy())
test/OracleToken.t.sol            unit and fuzz tests
```

## Tests

```bash
forge build
forge test
forge fmt --check
```

The tests cover: metadata; the exact supply; minting to the deployer whether an EOA, a contract or
the deploy script; the mint `Transfer` event; successful `transfer`/`approve`/`transferFrom` with
events and balance/allowance accounting; zero-value and self transfers; the unlimited allowance;
every revert path (insufficient balance, insufficient allowance, zero receiver, zero spender, no
allowance); the absence of mint/admin/freeze entry points; rejection of ETH and unknown selectors;
the opcode scan for `DELEGATECALL`/`CALLCODE`/`SELFDESTRUCT`; and fuzzed conservation of supply.
Tests read no environment variables and are order-independent.
