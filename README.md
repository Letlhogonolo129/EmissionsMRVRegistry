# EmissionsMRVRegistry

Solidity implementation of the permissioned MRV ledger designed in Parts A and B:
an append-only register of industrial greenhouse gas emissions records, their
off-chain evidence digests, and the independent verifier attestations made
against them.

## Contract

`contracts/EmissionsMRVRegistry.sol` — one contract, four labelled modules
corresponding to the four chaincodes in the system design:

| Module | Responsibility |
|---|---|
| 1 — Control and identity | Facility registration, verifier authorisation, per-facility operator and device identities, revocation |
| 2 — Emission recording | Append-only submission of readings and evidence digests; corrections by supersession |
| 3 — Verification and attestation | Verifier approve / query / reject, recorded as a separate signed step |
| 4 — Reporting and audit trail | Paginated retrieval, period aggregation, independent evidence re-check |

Solidity 0.8.28, no external dependencies. It is a single file with no imports,
so it can also be pasted directly into Remix.

## Setup

```bash
npm install
npm run build
npm test
```

## Deploying to a local node with MetaMask

```bash
npx hardhat node                                       # terminal 1
npx hardhat run scripts/deploy.js --network localhost  # terminal 2
```

The deploy script prints the contract address and transaction hash.

To sign from MetaMask instead, add a network with RPC URL `http://127.0.0.1:8545`
and chain ID `31337`, import one of the private keys printed by `hardhat node`,
then deploy through Remix with the **Injected Provider — MetaMask** environment
selected.

Note the constructor takes the regulator's address. It is not defaulted to
`msg.sender`, so the account that pays for deployment does not silently become
the consortium administrator.

## Demo

```bash
npx hardhat run scripts/demo.js --network localhost
```

Walks the full lifecycle: register a facility, appoint a human operator and a
sensor identity, submit a reading, watch an unauthorised submission and a
verifier's own submission both revert, query then approve, correct a rejected
record by supersession, aggregate an approved total, and re-check an evidence
digest against a tampered document.

## Design notes

- **Nothing is ever overwritten.** No function alters the facility, category,
  quantity, period, evidence hash, submitter or timestamp of a record once
  written. Only the verification status and the forward supersession pointer
  change. Corrections are new records that point back at the original.
- **Separation of duties is enforced in code.** A verifier cannot be authorised
  as an operator, an operator cannot attest, and the regulator can be neither.
- **Quantities are integer kilograms of CO2e.** The EVM has no floating point;
  rounding is a decision for the off-chain calculation layer, which submits a
  settled integer.
- **Every list is paginated.** A facility reporting daily accumulates thousands
  of records, and a view function returning an unbounded array will eventually
  exceed the node gas cap for `eth_call`.
- **Evidence lives off-chain.** The ledger stores a 32-byte digest. An auditor
  re-hashes the document in hand and calls `verifyEvidence` to confirm it is the
  document that was reported against.
