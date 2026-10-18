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
    assert.equal(report.minecraftScriptAPI.status, "not_tested");
    assert.equal(report.minecraftScriptAPI.importResolution, "not_supported_in_this_context");
    assert.equal(report.minecraftScriptAPI.entityQuery, "not_run");
    assert.equal(report.errors.length, 0);
    assert.match(report.limitations.join("\n"), /does not import or test the Minecraft API/);
    assert.equal(report["3105"].installerApplicationStatus, "not_independently_verified");
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
    assert.equal(report.minecraftScriptAPI.status, "not_tested");
    assert.equal(report.minecraftScriptAPI.entityQuery, "not_run");
    assert.deepEqual(report.errors, []);
}

{
    const result = runDiagnostic({}, "legacy");
    const { report, fileName } = result.reports[0];
    assert.equal(fileName, "MinecraftAPIDiagnostic.json");
    assert.equal(report.minecraftScriptAPI.status, "not_tested");
    assert.equal(report.nativeBridge.fallback, "ClientMenu.exportJSON");
    assert.match(result.notifications[0], /API was not tested by this check/);
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
    const patchDocuments = path.resolve(
        __dirname,
        "..",
        "3105",
        "Patches",
        "Minecraft",
        "Application",
        "com.mojang.minecraftpe",
        "Documents"
    );
    assert.equal(
        fs.existsSync(path.join(patchDocuments, "games", "com.mojang", "behavior_packs")),
        false,
        "3105 patch must not add or require a behavior pack."
    );
    assert.equal(
        fs.existsSync(path.join(patchDocuments, "games", "com.mojang", "resource_packs")),
        false,
        "3105 patch must not add or require a resource pack."
    );
}

{
    const nativeSource = fs.readFileSync(path.join(__dirname, "ClientLoader.m"), "utf8");
    assert.match(nativeSource, /reportRuntimeStatus/);
    assert.match(nativeSource, /URLByAppendingPathComponent:fileName/);
    assert.match(nativeSource, /diagnostics/);
    assert.match(nativeSource, /NSDataWritingAtomic/);
    assert.match(nativeSource, /3105 API diagnostic:/);
    assert.match(nativeSource, /Minecraft's @minecraft\/server API was not tested by this check/);
    assert.match(nativeSource, /not_tested/);
    assert.match(nativeSource, /not a live entity query/);
}

console.log("Minecraft API / 3105 diagnostic tests passed");
