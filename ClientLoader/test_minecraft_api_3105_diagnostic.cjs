const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const scriptPath = path.join(__dirname, "scripts", "minecraft_api_3105_diagnostic.js");
const source = fs.readFileSync(scriptPath, "utf8");

function runDiagnostic(globals, bridge = "native") {
    const captured = { reports: [], errors: [] };
    const clientMenu = {};
    if (bridge === "native") {
        clientMenu.reportRuntimeStatus = (json, fileName) => {
            captured.reports.push({ report: JSON.parse(json), fileName, bridge });
            return "/Documents/ClientLoader/diagnostics/" + fileName;
        };
    }
    if (bridge === "legacy") {
        clientMenu.exportJSON = (json, fileName) => {
            captured.reports.push({ report: JSON.parse(json), fileName, bridge });
            return "/Documents/ClientLoader/exports/" + fileName;
        };
        clientMenu.notify = (message) => { captured.notifications = [message]; };
    }
    const sandbox = {
        console: { error: (...args) => captured.errors.push(args) },
        ClientMenu: clientMenu,
        ...globals
    };
    vm.runInNewContext(source, sandbox, { filename: scriptPath });
    return captured;
}

{
    const result = runDiagnostic({});
    assert.equal(result.reports.length, 1);
    const { report, fileName } = result.reports[0];
    assert.equal(fileName, "MinecraftAPIDiagnostic.json");
    assert.equal(report.clientLoader.status, "running");
    assert.equal(report["3105"].status, "script_executed");
    assert.equal(report.minecraftScriptAPI.status, "unavailable");
    assert.match(report.errors.join("\n"), /separate context/);
}

{
    const result = runDiagnostic({
        world: {
            getDimension(name) {
                assert.equal(name, "overworld");
                return { getEntities: () => [{ id: "cow" }, { id: "sheep" }] };
            }
        },
        system: {}
    });
    const report = result.reports[0].report;
    assert.equal(report.minecraftScriptAPI.status, "available");
    assert.equal(report.minecraftScriptAPI.entityQuery.status, "succeeded");
    assert.equal(report.minecraftScriptAPI.entityQuery.entityCount, 2);
    assert.deepEqual(report.errors, []);
}

{
    const result = runDiagnostic({}, "legacy");
    const { report, fileName } = result.reports[0];
    assert.equal(fileName, "MinecraftAPIDiagnostic.json");
    assert.equal(report.minecraftScriptAPI.status, "unavailable");
    assert.equal(report.nativeBridge.fallback, "ClientMenu.exportJSON");
    assert.match(result.notifications[0], /Minecraft Script API is unavailable/);
}

{
    const result = runDiagnostic({
        world: { getDimension: () => ({ getEntities: () => { throw new Error("query denied"); } }) }
    });
    const report = result.reports[0].report;
    assert.equal(report.minecraftScriptAPI.status, "error");
    assert.match(report.errors[0], /query denied/);
}

{
    const result = runDiagnostic({
        world: { getDimension: () => ({ getEntities: () => ({}) }) }
    });
    assert.equal(result.reports[0].report.minecraftScriptAPI.status, "error");
    assert.match(result.reports[0].report.errors[0], /non-array result/);
}

{
    const sourceCopy = path.join(
        __dirname,
        "..",
        "3105",
        "Patches",
        "Minecraft",
        "Application",
        "com.mojang.minecraftpe",
        "Documents",
        "ClientLoader",
        "scripts",
        "minecraft_api_3105_diagnostic.js"
    );
    assert.equal(fs.readFileSync(sourceCopy, "utf8"), source);
}

{
    const packRoot = path.join(
        __dirname,
        "..",
        "3105",
        "Patches",
        "Minecraft",
        "Application",
        "com.mojang.minecraftpe",
        "Documents",
        "games",
        "com.mojang",
        "behavior_packs",
        "clientloader_api_diagnostic"
    );
    const manifest = JSON.parse(
        fs.readFileSync(path.join(packRoot, "manifest.json"), "utf8")
    );
    assert.equal(manifest.modules[0].type, "script");
    assert.equal(manifest.modules[0].entry, "scripts/main.js");
    assert.deepEqual(manifest.dependencies[0], {
        module_name: "@minecraft/server",
        version: "2.0.0"
    });

    const packSource = fs.readFileSync(
        path.join(packRoot, "scripts", "main.js"),
        "utf8"
    );
    assert.match(packSource, /^import \{ world, system \} from "@minecraft\/server";/);
    const executableSource = packSource.replace(
        /^import \{ world, system \} from "@minecraft\/server";\s*/,
        ""
    );
    assert.notEqual(executableSource, packSource);
    const notifications = [];
    let spawnCallback;
    const player = { sendMessage: (message) => notifications.push(message) };
    const testWorld = {
        getDimension: (id) => {
            assert.equal(id, "overworld");
            return { getEntities: () => [{}, {}] };
        },
        afterEvents: {
            playerSpawn: {
                subscribe: (callback) => { spawnCallback = callback; }
            }
        }
    };
    vm.runInNewContext(executableSource, {
        world: testWorld,
        system: { run: (callback) => callback() }
    });
    spawnCallback({ player });
    assert.match(notifications[0], /query succeeded; overworld entities: 2/);
    assert.match(notifications[1], /ClientLoader bridge status is separate/);

    notifications.length = 0;
    testWorld.getDimension = () => ({
        getEntities: () => { throw new Error("script API denied"); }
    });
    spawnCallback({ player });
    assert.match(notifications.join("\n"), /entity query failed/);
    assert.match(notifications.join("\n"), /script API denied/);

    notifications.length = 0;
    testWorld.getDimension = () => ({
        getEntities: () => {
            throw new Error("F".repeat(500));
        }
    });
    spawnCallback({ player });
    assert.ok(notifications.length >= 4);
    assert.ok(notifications.every((message) => message.length <= 255));
    const errorChunks = notifications.slice(1, -1)
        .map((message) => message.split("§r ")[1] || "");
    assert.ok(
        errorChunks.join("").includes("F".repeat(500)),
        "The complete caught error should be split across chat messages."
    );
}

{
    const nativeSource = fs.readFileSync(path.join(__dirname, "ClientLoader.m"), "utf8");
    assert.match(nativeSource, /reportRuntimeStatus/);
    assert.match(nativeSource, /URLByAppendingPathComponent:fileName/);
    assert.match(nativeSource, /diagnostics/);
    assert.match(nativeSource, /NSDataWritingAtomic/);
    assert.match(nativeSource, /3105 API diagnostic:/);
}

console.log("Minecraft API / 3105 diagnostic tests passed");
