import hre from "hardhat";
import { hashString } from "../utils/hash";
import { timelockWriteMulticall } from "../utils/timelock";

const expectedTimelockMethods = [
  "signalGrantRole",
  "grantRoleAfterSignal",
  "signalRevokeRole",
  "revokeRoleAfterSignal",
  "cancelGrantRole",
];

async function getTimelock() {
  const network = hre.network.name;

  if (network === "arbitrum") {
    return await ethers.getContractAt("Timelock", "0x2ECB664e934aCd5DF1EE889Dbb2E7D6C1d7CE3Cb");
  }

  if (network === "avalanche") {
    return await ethers.getContractAt("Timelock", "0x844D38f2c3875b8351feB4764718E1c64bD55c46");
  }

  throw new Error("Unsupported network");
}

async function getGrantRoleActionKeysToCancel({ timelock }) {
  const txHash = process.env.TX;
  if (!txHash) {
    throw new Error(
      "Missing TX env var. Example of usage: `TX=0x123... npx hardhat run scripts/decodeTransactionEvents.ts`"
    );
  }

  console.log("Retrieving transaction %s", txHash);

  const receipt = await hre.ethers.provider.getTransactionReceipt(txHash);
  if (!receipt) {
    throw new Error("Transaction not found");
  }

  const artifact = await hre.deployments.getArtifact("EventEmitter");
  const eventEmitterInterface = new hre.ethers.utils.Interface(artifact.abi);

  const actionKeys = [];
  for (const [i, log] of receipt.logs.entries()) {
    try {
      const parsedLog = eventEmitterInterface.parseLog(log);
      const eventName = parsedLog.args[1];
      if (eventName === "SignalGrantRole") {
        const actionKey = log.topics[2];
        const timestamp = await timelock.pendingActions(actionKey);
        if (timestamp.gt(0)) {
          actionKeys.push(actionKey);
        } else {
          console.warn(`No pending action found for ${actionKey}`);
        }
      }
    } catch (ex) {
      console.info("Can't parse log %s", i, ex);
    }
  }
  console.log("actionKeys", actionKeys);

  return actionKeys;
}

// to update roles
// 1. update roles in config/roles.ts
// 2. then run scripts/validateRoles.ts, it should output the role changes
// 3. update rolesToAdd and rolesToRemove here
// 4. then run e.g. WRITE=true TIMELOCK_METHOD=signalGrantRole npx hardhat run --network arbitrum scripts/updateRoles.ts
// 5. after the timelock delay, run WRITE=true TIMELOCK_METHOD=grantRoleAfterSignal npx hardhat run --network arbitrum scripts/updateRoles.ts
// see utils/signer.ts for steps on how to sign the transactions
async function main() {
  // NOTE: the existing Timelock needs to be used to grant roles to new contracts including new Timelocks
  const timelock = await getTimelock();

  const rolesToAdd = {
    arbitrum: [
      {
        role: "CONTROLLER",
        member: "0x7d36fe0840140aa2bb45711d8ec228e77f597493",
      },
      {
        role: "CONTROLLER",
        member: "0x8583b878da0844b7f59974069f00d3a9eae0f4ae",
      },
      {
        role: "CONTROLLER",
        member: "0xf32b417a93acc039b236f1ecc86b56bd3cb8e698",
      },
      {
        role: "ROLE_ADMIN",
        member: "0xf32b417a93acc039b236f1ecc86b56bd3cb8e698",
      },
    ],
    avalanche: [
      {
        role: "CONTROLLER",
        member: "0x162e3a5b47c9a45ff762e5b4b23d048d6780c14e",
      },
      {
        role: "CONTROLLER",
        member: "0x8efe46827aadfe498c27e56f0a428b5b4ee654f7",
      },
      {
        role: "CONTROLLER",
        member: "0x9dd6eb1069385d85ae204543babb7333181ec8a5",
      },
      {
        role: "ROLE_ADMIN",
        member: "0x9dd6eb1069385d85ae204543babb7333181ec8a5",
      },
    ],
  };

  const rolesToRemove = {
    arbitrum: [
      {
        role: "CONTROLLER",
        member: "0x2ECB664e934aCd5DF1EE889Dbb2E7D6C1d7CE3Cb",
      },
      {
        role: "CONTROLLER",
        member: "0xd0Db5Ea893ad4a89e5dBBD94fbD25F0273BBd74c",
      },
      {
        role: "ROLE_ADMIN",
        member: "0x2ECB664e934aCd5DF1EE889Dbb2E7D6C1d7CE3Cb",
      },
    ],
    avalanche: [
      {
        role: "CONTROLLER",
        member: "0x844D38f2c3875b8351feB4764718E1c64bD55c46",
      },
      {
        role: "CONTROLLER",
        member: "0x8514fc704317057FA86961Ba9b9490956993A5ed",
      },
      {
        role: "ROLE_ADMIN",
        member: "0x844D38f2c3875b8351feB4764718E1c64bD55c46",
      },
    ],
  };

  const multicallWriteParams = [];

  const timelockMethod = process.env.TIMELOCK_METHOD;
  if (!expectedTimelockMethods.includes(timelockMethod)) {
    throw new Error(`Unexpected TIMELOCK_METHOD: ${timelockMethod}`);
  }

  if (["signalGrantRole", "grantRoleAfterSignal"].includes(timelockMethod)) {
    for (const { member, role } of rolesToAdd[hre.network.name]) {
      multicallWriteParams.push(timelock.interface.encodeFunctionData(timelockMethod, [member, hashString(role)]));
    }
  }

  if (timelockMethod === "signalRevokeRole") {
    for (const { member, role } of rolesToRemove[hre.network.name]) {
      multicallWriteParams.push(timelock.interface.encodeFunctionData(timelockMethod, [member, hashString(role)]));
      // signalGrantRole in case the revocation of the role needs to be reverted
      multicallWriteParams.push(timelock.interface.encodeFunctionData("signalGrantRole", [member, hashString(role)]));
    }
  }

  if (timelockMethod === "revokeRoleAfterSignal") {
    for (const { member, role } of rolesToRemove[hre.network.name]) {
      multicallWriteParams.push(timelock.interface.encodeFunctionData(timelockMethod, [member, hashString(role)]));
    }
  }

  if (timelockMethod === "cancelGrantRole") {
    const actionKeys = await getGrantRoleActionKeysToCancel({ timelock });
    for (const actionKey of actionKeys) {
      multicallWriteParams.push(timelock.interface.encodeFunctionData("cancelAction", [actionKey]));
    }
  }

  console.log(`updating ${multicallWriteParams.length} roles`);
  await timelockWriteMulticall({ timelock, multicallWriteParams });
}

main().catch((ex) => {
  console.error(ex);
  process.exit(1);
});
