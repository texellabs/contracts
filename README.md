# Texel contracts

The contracts of [Texel](https://texel.run), the onchain GPU cloud on Robinhood Chain.

[![Texel on HEY Research Lab](https://heyresearch.xyz/api/badge/texel?style=pill)](https://heyresearch.xyz/project/texel?utm_source=badge&utm_medium=readme)

| Contract | Address on Robinhood Chain | What it does |
|---|---|---|
| `TexelReceipts` | [`0x48c545Fdd2Ea5b286B319F03575683019C2f1EF5`](https://robin.etherscan.io/address/0x48c545Fdd2Ea5b286B319F03575683019C2f1EF5) | Keeps one Merkle root for each UTC hour of receipts. |
| `TexelEarn` | [`0x8722779110FC73d9d6f189843FC48F7cd04238BC`](https://robin.etherscan.io/address/0x8722779110FC73d9d6f189843FC48F7cd04238BC) | Pays tokenized NVDA to every wallet with $TEXEL. |
| `TexelDeposits` | [`0x69d11407269d7949cb7652a8Ca6B65f31E1fc6C4`](https://robin.etherscan.io/address/0x69d11407269d7949cb7652a8Ca6B65f31E1fc6C4) | Takes the USDG that buys Texel credits and sends it on to the treasury. |

$TEXEL is [`0x0ddcab9ae04bda0c87ecc1640636fa11e8e613e8`](https://robin.etherscan.io/token/0x0ddcab9ae04bda0c87ecc1640636fa11e8e613e8).

## TexelReceipts

Every GPU rental and every output on Texel gets a receipt. A receipt holds the GPU or the model,
its size or its seconds, the credits it took, its hour, and whether it was free. It holds no prompt
and no file, and a wallet code stands in place of the wallet.

After each UTC hour, the gateway of Texel seals that hour here with one Merkle root of its receipts
and their count. An hour is sealed once and never changes, so a receipt changed later stops matching
the chain. The contract holds no money, has no owner, and cannot be upgraded.

Every sealed hour is on [texel.run/receipts](https://texel.run/receipts).

## TexelDeposits

A wallet buys Texel credits by sending USDG to this contract in one plain transfer, with no
approval and no signature. The gateway of Texel reads each Transfer of USDG to the contract and adds
the credits to the wallet that sent it. Anyone can call `forward`, which sends all of a token that
the contract holds to the treasury, the one place a token can leave to. USDG and the treasury are
fixed at the deploy. The contract has no owner, refuses ETH, and cannot be upgraded.

## TexelEarn

Every wallet with $TEXEL gets tokenized NVDA, split by how much $TEXEL it held over each round. Each
round, Texel publishes one Merkle root of the NVDA that every wallet has earned since the first
round, then sends each wallet its NVDA and pays the gas. Anyone can send a claim, and the NVDA always
goes to the wallet in the leaf.

Three rules keep the NVDA of the wallets safe:

- `allocated`, the NVDA that the roots hold, never goes down.
- A root is published only while the contract holds all of its NVDA that is not claimed yet.
- Claims never pay more in total than `allocated`.

The owner can take back only `surplus()`, the NVDA that no root holds yet. The contract cannot be
upgraded.

How Earn works: [texel.run/docs#earn](https://texel.run/docs#earn).

## Build and test

The contracts use [Foundry](https://getfoundry.sh) with Solidity 0.8.30, the Cancun EVM, and the
optimizer at 10,000 runs.

```sh
git clone --recurse-submodules https://github.com/texellabs/contracts.git
cd contracts
forge build
forge test
```

The fork test of `TexelEarn` runs it against the real tokenized NVDA of Robinhood Chain:

```sh
EARN_FORK_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-contract Fork
```

The fork test of `TexelDeposits` sends the real USDG of Robinhood Chain through it:

```sh
DEPOSITS_FORK_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-contract TexelDepositsFork
```

## License

[MIT](LICENSE)
