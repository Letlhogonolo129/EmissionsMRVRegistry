const { expect } = require("chai");
const { ethers } = require("hardhat");

// Enum mirrors, so the tests read the way the contract does.
const ActorKind = { Human: 0, Device: 1 };
const Category = { Scope1Combustion: 0, Scope1Process: 1, Scope2Electricity: 2 };
const Status = { Submitted: 0, Approved: 1, Queried: 2, Rejected: 3, Superseded: 4 };
const Outcome = { Approve: 0, Query: 1, Reject: 2 };

const hash = (s) => ethers.keccak256(ethers.toUtf8Bytes(s));

describe("EmissionsMRVRegistry", function () {
  let registry, deployer, regulator, manufacturer, operator, sensor, verifier, outsider;
  let periodStart, periodEnd;

  beforeEach(async function () {
    [deployer, regulator, manufacturer, operator, sensor, verifier, outsider] =
      await ethers.getSigners();

    const Factory = await ethers.getContractFactory("EmissionsMRVRegistry");
    registry = await Factory.deploy(regulator.address);
    await registry.waitForDeployment();

    // A reporting period that has already closed.
    const now = (await ethers.provider.getBlock("latest")).timestamp;
    periodEnd = now - 60;
    periodStart = periodEnd - 30 * 24 * 60 * 60;
  });

  async function bootstrap() {
    await registry.connect(regulator).registerFacility(
      "Vereeniging Industrial Works",
      "Gauteng, South Africa",
      manufacturer.address
    );
    await registry.connect(regulator).authoriseVerifier(verifier.address);
    await registry
      .connect(manufacturer)
      .authoriseOperator(1, operator.address, ActorKind.Human, hash("employment-record-001"));
    await registry
      .connect(manufacturer)
      .authoriseOperator(1, sensor.address, ActorKind.Device, hash("calibration-cert-CEMS-07"));
  }

  async function submit(signer = operator, evidence = "evidence-2026-07") {
    const tx = await registry
      .connect(signer)
      .submitEmissionRecord(1, Category.Scope1Combustion, 4_250_000, periodStart, periodEnd, hash(evidence));
    await tx.wait();
    return tx;
  }

  describe("deployment and governance", function () {
    it("sets the regulator passed to the constructor, not the deployer", async function () {
      expect(await registry.regulator()).to.equal(regulator.address);
      expect(await registry.regulator()).to.not.equal(deployer.address);
    });

    it("rejects a zero-address regulator", async function () {
      const Factory = await ethers.getContractFactory("EmissionsMRVRegistry");
      await expect(Factory.deploy(ethers.ZeroAddress)).to.be.revertedWithCustomError(
        registry,
        "ZeroAddress"
      );
    });
  });

  describe("Module 1 — control and identity", function () {
    it("lets the regulator register a facility and emits the event", async function () {
      await expect(
        registry
          .connect(regulator)
          .registerFacility("Vaal Works", "Gauteng", manufacturer.address)
      )
        .to.emit(registry, "FacilityRegistered")
        .withArgs(1, manufacturer.address, "Vaal Works", "Gauteng", anyUint());
      expect(await registry.facilityCount()).to.equal(1);
    });

    it("stops anyone other than the regulator registering a facility", async function () {
      await expect(
        registry
          .connect(manufacturer)
          .registerFacility("Rogue Plant", "Nowhere", manufacturer.address)
      ).to.be.revertedWithCustomError(registry, "NotRegulator");
    });

    it("rejects empty facility name or location", async function () {
      await expect(
        registry.connect(regulator).registerFacility("", "Gauteng", manufacturer.address)
      ).to.be.revertedWithCustomError(registry, "EmptyField");
    });

    it("lets the manufacturer appoint its own staff, but not the regulator", async function () {
      await bootstrap();
      await expect(
        registry
          .connect(regulator)
          .authoriseOperator(1, outsider.address, ActorKind.Human, hash("x"))
      ).to.be.revertedWithCustomError(registry, "NotManufacturer");
    });

    it("enforces separation of duties: a verifier cannot become an operator", async function () {
      await bootstrap();
      await expect(
        registry
          .connect(manufacturer)
          .authoriseOperator(1, verifier.address, ActorKind.Human, hash("x"))
      ).to.be.revertedWithCustomError(registry, "SeparationOfDuties");
    });

    it("records the device kind for a sensor identity", async function () {
      await bootstrap();
      const op = await registry.getOperator(1, sensor.address);
      expect(op.kind).to.equal(ActorKind.Device);
      expect(op.active).to.equal(true);
    });

    it("revocation blocks future submissions but leaves past records readable", async function () {
      await bootstrap();
      await submit();
      await registry.connect(manufacturer).revokeOperator(1, operator.address);
      await expect(submit(operator, "evidence-later")).to.be.revertedWithCustomError(
        registry,
        "NotFacilityOperator"
      );
      const record = await registry.getRecord(1);
      expect(record.submitter).to.equal(operator.address);
    });
  });

  describe("Module 2 — emission recording", function () {
    beforeEach(bootstrap);

    it("accepts a valid record from an authorised operator", async function () {
      await expect(submit()).to.emit(registry, "EmissionRecordSubmitted");
      const record = await registry.getRecord(1);
      expect(record.quantityKgCO2e).to.equal(4_250_000);
      expect(record.status).to.equal(Status.Submitted);
      expect(record.supersedes).to.equal(0);
    });

    it("blocks an unauthorised address from submitting", async function () {
      await expect(submit(outsider)).to.be.revertedWithCustomError(
        registry,
        "NotFacilityOperator"
      );
    });

    it("blocks a verifier from submitting its own data", async function () {
      await expect(submit(verifier)).to.be.revertedWithCustomError(
        registry,
        "NotFacilityOperator"
      );
    });

    it("rejects a zero quantity and an implausibly large one", async function () {
      await expect(
        registry
          .connect(operator)
          .submitEmissionRecord(1, Category.Scope1Process, 0, periodStart, periodEnd, hash("a"))
      ).to.be.revertedWithCustomError(registry, "InvalidQuantity");

      await expect(
        registry
          .connect(operator)
          .submitEmissionRecord(1, Category.Scope1Process, 10n ** 13n, periodStart, periodEnd, hash("b"))
      ).to.be.revertedWithCustomError(registry, "InvalidQuantity");
    });

    it("rejects an inverted period and a period that has not closed", async function () {
      await expect(
        registry
          .connect(operator)
          .submitEmissionRecord(1, Category.Scope1Process, 100, periodEnd, periodStart, hash("c"))
      ).to.be.revertedWithCustomError(registry, "InvalidPeriod");

      const future = periodEnd + 10 * 24 * 60 * 60;
      await expect(
        registry
          .connect(operator)
          .submitEmissionRecord(1, Category.Scope1Process, 100, periodStart, future, hash("d"))
      ).to.be.revertedWithCustomError(registry, "PeriodNotElapsed");
    });

    it("rejects a zero evidence hash", async function () {
      await expect(
        registry
          .connect(operator)
          .submitEmissionRecord(
            1,
            Category.Scope1Process,
            100,
            periodStart,
            periodEnd,
            ethers.ZeroHash
          )
      ).to.be.revertedWithCustomError(registry, "ZeroHash");
    });

    it("rejects the same evidence bundle being submitted twice", async function () {
      await submit();
      await expect(submit(sensor, "evidence-2026-07")).to.be.revertedWithCustomError(
        registry,
        "DuplicateEvidence"
      );
    });

    it("rejects submissions to an unknown or deactivated facility", async function () {
      await expect(
        registry
          .connect(operator)
          .submitEmissionRecord(99, Category.Scope1Process, 100, periodStart, periodEnd, hash("e"))
      ).to.be.revertedWithCustomError(registry, "UnknownFacility");

      await registry.connect(regulator).deactivateFacility(1);
      await expect(submit()).to.be.revertedWithCustomError(registry, "FacilityInactive");
    });

    it("exposes no function that can alter a submitted figure", async function () {
      // The ABI is the proof: nothing writes to quantityKgCO2e except the append path.
      const writers = registry.interface.fragments
        .filter((f) => f.type === "function" && f.stateMutability !== "view")
        .map((f) => f.name);
      expect(writers).to.have.members([
        "registerFacility",
        "deactivateFacility",
        "authoriseVerifier",
        "revokeVerifier",
        "authoriseOperator",
        "revokeOperator",
        "submitEmissionRecord",
        "submitCorrection",
        "attest",
      ]);
    });
  });

  describe("Module 3 — verification and attestation", function () {
    beforeEach(async function () {
      await bootstrap();
      await submit();
    });

    it("lets an authorised verifier approve a record", async function () {
      await expect(registry.connect(verifier).attest(1, Outcome.Approve, hash("opinion")))
        .to.emit(registry, "RecordAttested")
        .withArgs(1, verifier.address, Outcome.Approve, hash("opinion"));
      expect((await registry.getRecord(1)).status).to.equal(Status.Approved);
    });

    it("blocks the operator from attesting to its own submission", async function () {
      await expect(
        registry.connect(operator).attest(1, Outcome.Approve, hash("self-signed"))
      ).to.be.revertedWithCustomError(registry, "NotVerifier");
    });

    it("blocks the regulator from attesting", async function () {
      await expect(
        registry.connect(regulator).attest(1, Outcome.Approve, hash("opinion"))
      ).to.be.revertedWithCustomError(registry, "NotVerifier");
    });

    it("keeps a queried record open for a second attestation", async function () {
      await registry.connect(verifier).attest(1, Outcome.Query, hash("query-1"));
      expect((await registry.getRecord(1)).status).to.equal(Status.Queried);

      await registry.connect(verifier).attest(1, Outcome.Approve, hash("opinion-after-query"));
      expect((await registry.getRecord(1)).status).to.equal(Status.Approved);

      const trail = await registry.getAttestations(1);
      expect(trail.length).to.equal(2);
      expect(trail[0].outcome).to.equal(Outcome.Query);
      expect(trail[1].outcome).to.equal(Outcome.Approve);
    });

    it("treats approval and rejection as terminal", async function () {
      await registry.connect(verifier).attest(1, Outcome.Approve, hash("opinion"));
      await expect(
        registry.connect(verifier).attest(1, Outcome.Reject, hash("second-thoughts"))
      ).to.be.revertedWithCustomError(registry, "RecordNotOpen");
    });

    it("rejects attestation against an unknown record", async function () {
      await expect(
        registry.connect(verifier).attest(99, Outcome.Approve, hash("opinion"))
      ).to.be.revertedWithCustomError(registry, "UnknownRecord");
    });

    it("stops a revoked verifier attesting, without disturbing past attestations", async function () {
      await registry.connect(verifier).attest(1, Outcome.Query, hash("query-1"));
      await registry.connect(regulator).revokeVerifier(verifier.address);
      await expect(
        registry.connect(verifier).attest(1, Outcome.Approve, hash("late"))
      ).to.be.revertedWithCustomError(registry, "NotVerifier");
      expect((await registry.getAttestations(1)).length).to.equal(1);
    });
  });

  describe("corrections by supersession", function () {
    beforeEach(async function () {
      await bootstrap();
      await submit();
    });

    it("refuses to supersede a record still under review", async function () {
      await expect(
        registry
          .connect(operator)
          .submitCorrection(1, Category.Scope1Combustion, 4_400_000, periodStart, periodEnd, hash("v2"))
      ).to.be.revertedWithCustomError(registry, "RecordNotSupersedable");
    });

    it("links the correction to the original and preserves the original figure", async function () {
      await registry.connect(verifier).attest(1, Outcome.Reject, hash("rejected"));
      await expect(
        registry
          .connect(operator)
          .submitCorrection(1, Category.Scope1Combustion, 4_400_000, periodStart, periodEnd, hash("v2"))
      )
        .to.emit(registry, "RecordSuperseded")
        .withArgs(1, 2);

      const original = await registry.getRecord(1);
      const correction = await registry.getRecord(2);

      expect(original.quantityKgCO2e).to.equal(4_250_000); // untouched
      expect(original.status).to.equal(Status.Superseded);
      expect(original.supersededBy).to.equal(2);
      expect(correction.supersedes).to.equal(1);
      expect(await registry.isCurrent(1)).to.equal(false);
      expect(await registry.isCurrent(2)).to.equal(true);
    });

    it("refuses to supersede the same record twice", async function () {
      await registry.connect(verifier).attest(1, Outcome.Reject, hash("rejected"));
      await registry
        .connect(operator)
        .submitCorrection(1, Category.Scope1Combustion, 4_400_000, periodStart, periodEnd, hash("v2"));
      await expect(
        registry
          .connect(operator)
          .submitCorrection(1, Category.Scope1Combustion, 4_500_000, periodStart, periodEnd, hash("v3"))
      ).to.be.revertedWithCustomError(registry, "AlreadySuperseded");
    });

    it("blocks an outsider filing a correction", async function () {
      await registry.connect(verifier).attest(1, Outcome.Reject, hash("rejected"));
      await expect(
        registry
          .connect(outsider)
          .submitCorrection(1, Category.Scope1Combustion, 1, periodStart, periodEnd, hash("v2"))
      ).to.be.revertedWithCustomError(registry, "NotFacilityOperator");
    });
  });

  describe("Module 4 — reporting and audit trail", function () {
    beforeEach(bootstrap);

    it("counts only approved, current, in-window records in a total", async function () {
      // 1: approved, in window            -> counts
      // 2: submitted but never attested   -> excluded
      // 3: rejected then superseded by 4  -> excluded
      // 4: approved correction            -> counts
      await submit(operator, "e1");
      await registry.connect(verifier).attest(1, Outcome.Approve, hash("o1"));

      await submit(sensor, "e2");

      await submit(operator, "e3");
      await registry.connect(verifier).attest(3, Outcome.Reject, hash("o3"));
      await registry
        .connect(operator)
        .submitCorrection(3, Category.Scope1Process, 1_000_000, periodStart, periodEnd, hash("e4"));
      await registry.connect(verifier).attest(4, Outcome.Approve, hash("o4"));

      const [total, matched, nextOffset] = await registry.approvedTotal(
        1,
        periodStart,
        periodEnd,
        0,
        100
      );
      expect(total).to.equal(4_250_000 + 1_000_000);
      expect(matched).to.equal(2);
      expect(nextOffset).to.equal(4);
    });

    it("excludes records whose period falls outside the requested window", async function () {
      await submit(operator, "e1");
      await registry.connect(verifier).attest(1, Outcome.Approve, hash("o1"));
      const [total] = await registry.approvedTotal(1, periodEnd - 10, periodEnd, 0, 100);
      expect(total).to.equal(0);
    });

    it("pages through record IDs", async function () {
      await submit(operator, "e1");
      await submit(sensor, "e2");
      await submit(operator, "e3");

      let [page, next] = await registry.getFacilityRecordIds(1, 0, 2);
      expect(page.map(Number)).to.deep.equal([1, 2]);
      expect(next).to.equal(2);

      [page, next] = await registry.getFacilityRecordIds(1, next, 2);
      expect(page.map(Number)).to.deep.equal([3]);
      expect(next).to.equal(3);
    });

    it("rejects an out-of-range pagination offset", async function () {
      await expect(
        registry.getFacilityRecordIds(1, 5, 10)
      ).to.be.revertedWithCustomError(registry, "PaginationOutOfRange");
    });

    it("lets an auditor confirm or refute an evidence document", async function () {
      await submit(operator, "sensor-log-july-2026");
      expect(await registry.verifyEvidence(1, hash("sensor-log-july-2026"))).to.equal(true);
      expect(await registry.verifyEvidence(1, hash("sensor-log-july-2026-TAMPERED"))).to.equal(
        false
      );
    });

    it("is readable by a party with no role at all", async function () {
      await submit();
      const record = await registry.connect(outsider).getRecord(1);
      expect(record.facilityId).to.equal(1);
    });
  });
});

// Small helper: matches any uint argument in an event assertion.
function anyUint() {
  return (value) => typeof value === "bigint" && value >= 0n;
}
