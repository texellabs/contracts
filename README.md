# Texel contracts

The contracts of [Texel](https://texel.run), the onchain GPU cloud on Robinhood Chain.

| Contract | Address on Robinhood Chain | What it does |
|---|---|---|
| `TexelReceipts` | [`0x48c545Fdd2Ea5b286B319F03575683019C2f1EF5`](https://robin.etherscan.io/address/0x48c545Fdd2Ea5b286B319F03575683019C2f1EF5) | Keeps one Merkle root for each UTC hour of receipts. |
| `TexelEarn` | [`0x8722779110FC73d9d6f189843FC48F7cd04238BC`](https://robin.etherscan.io/address/0x8722779110FC73d9d6f189843FC48F7cd04238BC) | Pays tokenized NVDA to every wallet with $TEXEL. |

$TEXEL is [`0x0ddcab9ae04bda0c87ecc1640636fa11e8e613e8`](https://robin.etherscan.io/token/0x0ddcab9ae04bda0c87ecc1640636fa11e8e613e8).

## TexelReceipts

Every GPU rental and every output on Texel gets a receipt. A receipt holds the GPU or the model,
its size or its seconds, the credits it took, its hour, and whether it was free. It holds no prompt
and no file, and a wallet code stands in place of the wallet.

After each UTC hour, the gateway of Texel seals that hour here with one Merkle root of its receipts
and their count. An hour is sealed once and never changes, so a receipt changed later stops matching
the chain. The contract holds no money, has no owner, and cannot be upgraded.

Every sealed hour is on [texel.run/receipts](https://texel.run/receipts).

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

The fork test runs `TexelEarn` against the real tokenized NVDA of Robinhood Chain:

```sh
EARN_FORK_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-contract Fork
```

## License

[MIT](LICENSE)
