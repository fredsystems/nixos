// Read-only Z-Wave inventory: raw NVM backup first, then every node's status.
// Usage: node zwave-inventory.cjs <serial port> <output dir>
//
// Nothing else may hold the port (stop zwave-js first). Run it detached so
// it outlives the SSH session, with zwave-js installed next to it:
//
//   npm install zwave-js@15.32.3
//   sudo systemd-run --unit=zwave-inventory --working-directory="$PWD" \
//     -p StandardOutput=file:"$PWD/run.out" -p StandardError=file:"$PWD/run.out" \
//     "$(command -v node)" zwave-inventory.cjs /dev/serial/by-id/... "$PWD/run"
//
// zwave-js has no read-only mode; the controller still updates its own
// routing bytes in NVM during traffic.
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { Driver, NodeStatus, InterviewStage } = require("zwave-js");
const { CommandClasses } = require("@zwave-js/core");

const [port, outDir] = process.argv.slice(2);
if (!port || !outDir) {
  console.error("usage: node zwave-inventory.cjs <port> <outdir>");
  process.exit(2);
}
fs.mkdirSync(outDir, { recursive: true });
const cacheDir = fs.mkdtempSync(path.join(outDir, "cache-"));

const driver = new Driver(port, {
  storage: { cacheDir },
  logConfig: {
    enabled: true,
    level: "debug",
    logToFile: true,
    filename: path.join(outDir, "zwavejs_%DATE%.log"),
    forceConsole: false,
  },
  features: { softReset: false },
});

let finished = false;
async function finish(code) {
  if (finished) return;
  finished = true;
  try {
    await driver.destroy();
  } catch (e) {
    console.error("destroy failed:", e);
  }
  process.exit(code);
}

driver.on("error", (e) => console.error("driver error:", e));
process.on("SIGINT", () => finish(130));

const statusName = (s) => NodeStatus[s] ?? String(s);

async function switchState(node) {
  const ccs = [
    [CommandClasses["Multilevel Switch"], "currentValue"],
    [CommandClasses["Binary Switch"], "currentValue"],
  ];
  for (const [cc, property] of ccs) {
    if (!node.supportsCC(cc)) continue;
    try {
      const v = await node.pollValue({
        commandClass: cc,
        endpoint: 0,
        property,
      });
      return { cc: CommandClasses[cc], value: v ?? null };
    } catch (e) {
      return { cc: CommandClasses[cc], error: String(e.message ?? e) };
    }
  }
  return null;
}

driver.once("driver ready", async () => {
  const c = driver.controller;
  const controller = {
    homeId: c.homeId?.toString(16).padStart(8, "0"),
    ownNodeId: c.ownNodeId,
    sucNodeId: c.sucNodeId,
    isPrimary: c.isPrimary,
    isSUC: c.isSUC,
    isSIS: c.isSIS,
    manufacturerId: c.manufacturerId,
    productType: c.productType,
    productId: c.productId,
    firmwareVersion: c.firmwareVersion,
    sdkVersion: c.sdkVersion,
    zwaveApiVersion: c.zwaveApiVersion,
    rfRegion: c.rfRegion,
  };
  console.log("controller:", JSON.stringify(controller));

  const nvm = await c.backupNVMRaw();
  const nvmFile = path.join(
    outDir,
    `nvm-${controller.homeId}-${Date.now()}.bin`,
  );
  fs.writeFileSync(nvmFile, nvm);
  console.log(`nvm backup: ${nvmFile} (${nvm.length} bytes)`);

  const settled = (n) =>
    n.isControllerNode ||
    n.ready ||
    n.status === NodeStatus.Dead ||
    n.status === NodeStatus.Asleep;

  const deadline = Date.now() + 8 * 60 * 1000;
  for (;;) {
    const nodes = [...c.nodes.values()];
    const pending = nodes.filter((n) => !settled(n));
    if (pending.length === 0 || Date.now() > deadline) break;
    console.log(
      `waiting on ${pending.length} node(s): ${pending.map((n) => n.id).join(",")}`,
    );
    await new Promise((r) => setTimeout(r, 15000));
  }

  const nodes = [];
  for (const n of [...c.nodes.values()].sort((a, b) => a.id - b.id)) {
    if (n.isControllerNode) continue;
    const entry = {
      id: n.id,
      status: statusName(n.status),
      ready: n.ready,
      interviewStage: InterviewStage[n.interviewStage],
      listening: n.isListening,
      flirs: n.isFrequentListening,
      manufacturer: n.deviceConfig?.manufacturer ?? null,
      label: n.deviceConfig?.label ?? null,
      description: n.deviceConfig?.description ?? null,
      firmware: n.firmwareVersion ?? null,
      securityClass: n.getHighestSecurityClass?.() ?? null,
    };
    if (n.status === NodeStatus.Alive) {
      try {
        entry.switch = await switchState(n);
      } catch (e) {
        entry.switch = { error: String(e.message ?? e) };
      }
    }
    nodes.push(entry);
  }

  const kind = (n) =>
    n.listening
      ? "mains"
      : n.flirs
        ? "flirs"
        : n.listening === false
          ? "battery"
          : "unknown";
  const summary = {};
  for (const n of nodes) {
    const k = `${kind(n)}/${n.status}`;
    summary[k] = (summary[k] ?? 0) + 1;
  }

  const report = {
    takenAt: new Date().toISOString(),
    port,
    controller,
    summary,
    nodes,
  };
  const reportFile = path.join(outDir, "inventory.json");
  fs.writeFileSync(reportFile, JSON.stringify(report, null, 2));
  console.log("summary:", JSON.stringify(summary));
  console.log(`report: ${reportFile}`);
  await finish(0);
});

driver.start().catch((e) => {
  console.error("start failed:", e);
  finish(1);
});
