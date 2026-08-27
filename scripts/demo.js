// Walks the full MRV lifecycle end to end, printing each step.
// Intended as the spine of the five-minute video demonstration.
//
//   npx hardhat run scripts/demo.js --network localhost
//
// Steps: register a facility -> appoint a human operator and a sensor identity
// -> submit a reading -> show an unauthorised submission being rejected ->
// verifier queries, then approves -> file a correction that supersedes a
// rejected record -> aggregate an approved total -> re-check an evidence digest.

const { ethers } = require("hardhat");

const ActorKind = { Human: 0, Device: 1 };
const Category = { Scope1Combustion: 0, Scope1Process: 1, Scope2Electricity: 2 };
const Outcome = { Approve: 0, Query: 1, Reject: 2 };
const StatusName = ["Submitted", "Approved", "Queried", "Rejected", "Superseded"];

const digest = (s) => ethers.keccak256(ethers.toUtf8Bytes(s));
const tonnes = (kg) => (Number(kg) / 1000).toLocaleString("en-ZA") + " t CO2e";

function step(n, text) {
  console.log(`\n--- ${n}. ${text} ---`);
}

async function main() {
  const [deployer, regulator, manufacturer, operator, sensor, verifier, outsider] =
    await ethers.getSigners();

  const Factory = await ethers.getContractFactory("EmissionsMRVRegistry");
  const registry = await Factory.deploy(regulator.address);
  await registry.waitForDeployment();
  console.log("Registry deployed at", await registry.getAddress());

  const now = (await ethers.provider.getBlock("latest")).timestamp;
  const periodEnd = now - 60;
  const periodStart = periodEnd - 30 * 24 * 60 * 60;

  step(1, "Regulator registers a facility and authorises a verifier");
  await registry
    .connect(regulator)
    .registerFacility("Vereeniging Industrial Works", "Gauteng, South Africa", manufacturer.address);
  await registry.connect(regulator).authoriseVerifier(verifier.address);
  const facility = await registry.getFacility(1);
  console.log(`   Facility 1: ${facility.name}, operator org ${facility.manufacturer}`);

  step(2, "Manufacturer appoints its own staff member and provisions a sensor key");
  await registry
    .connect(manufacturer)
    .authoriseOperator(1, operator.address, ActorKind.Human, digest("employment-record-4471"));
  await registry
    .connect(manufacturer)
    .authoriseOperator(1, sensor.address, ActorKind.Device, digest("calibration-cert-CEMS-07"));
  console.log("   Human operator and device identity registered against facility 1");

  step(3, "Authorised operator submits a reading with its evidence digest");
  await registry
    .connect(operator)
    .submitEmissionRecord(1, Category.Scope1Combustion, 4_250_000, periodStart, periodEnd, digest("sensor-log-2026-07"));
  let record = await registry.getRecord(1);
  console.log(`   Record 1: ${tonnes(record.quantityKgCO2e)} — status ${StatusName[record.status]}`);

  step(4, "An unauthorised address tries the same thing");
  try {
    await registry
      .connect(outsider)
      .submitEmissionRecord(1, Category.Scope1Combustion, 10, periodStart, periodEnd, digest("forged"));
    console.log("   ERROR: this should not have succeeded");
  } catch (e) {
    console.log("   Reverted:", e.shortMessage || e.message.split("\n")[0]);
  }

  step(5, "So does the verifier, who may certify but never report");
  try {
    await registry
      .connect(verifier)
      .submitEmissionRecord(1, Category.Scope1Combustion, 10, periodStart, periodEnd, digest("verifier-authored"));
    console.log("   ERROR: this should not have succeeded");
  } catch (e) {
    console.log("   Reverted:", e.shortMessage || e.message.split("\n")[0]);
  }

  step(6, "Verifier raises a query, the operator answers off-chain, verifier approves");
  await registry.connect(verifier).attest(1, Outcome.Query, digest("query-fuel-factor-source"));
  console.log(`   After query:   ${StatusName[(await registry.getRecord(1)).status]}`);
  await registry.connect(verifier).attest(1, Outcome.Approve, digest("iso-14064-3-opinion-001"));
  console.log(`   After approve: ${StatusName[(await registry.getRecord(1)).status]}`);
  const trail = await registry.getAttestations(1);
  console.log(`   Attestation trail length: ${trail.length} (both steps remain visible)`);

  step(7, "A second record is rejected, then corrected by supersession");
  await registry
    .connect(sensor)
    .submitEmissionRecord(1, Category.Scope1Process, 900_000, periodStart, periodEnd, digest("process-log-2026-07"));
  await registry.connect(verifier).attest(2, Outcome.Reject, digest("rejected-wrong-factor"));
  await registry
    .connect(operator)
    .submitCorrection(2, Category.Scope1Process, 1_000_000, periodStart, periodEnd, digest("process-log-2026-07-rev2"));
  await registry.connect(verifier).attest(3, Outcome.Approve, digest("iso-14064-3-opinion-002"));

  const original = await registry.getRecord(2);
  const correction = await registry.getRecord(3);
  console.log(`   Record 2 (original):   ${tonnes(original.quantityKgCO2e)} — ${StatusName[original.status]}, superseded by ${original.supersededBy}`);
  console.log(`   Record 3 (correction): ${tonnes(correction.quantityKgCO2e)} — ${StatusName[correction.status]}, supersedes ${correction.supersedes}`);
  console.log("   The original figure is still on the ledger. Nothing was overwritten.");

  step(8, "Regulator aggregates the approved, still-current total for the period");
  const [total, matched] = await registry.approvedTotal(1, periodStart, periodEnd, 0, 100);
  console.log(`   ${matched} approved records — total ${tonnes(total)}`);

  step(9, "Auditor re-hashes the evidence document and checks it against the ledger");
  console.log("   Genuine document :", await registry.verifyEvidence(1, digest("sensor-log-2026-07")));
  console.log("   Altered document :", await registry.verifyEvidence(1, digest("sensor-log-2026-07-EDITED")));
  console.log("");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
