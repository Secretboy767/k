(function () {
    "use strict";

    var errors = [];
    var probes = {
        clientMenuBridge: typeof ClientMenu !== "undefined",
        minecraftWorldGlobal: typeof world !== "undefined",
        minecraftSystemGlobal: typeof system !== "undefined"
    };
    var apiStatus = "unavailable";
    var entityCount = null;

    if (!probes.clientMenuBridge) {
        errors.push("ClientMenu bridge is unavailable; ClientLoader did not inject its script API.");
    }

    if (!probes.minecraftWorldGlobal) {
        errors.push(
            "Minecraft Script API global 'world' is not exposed in the ClientLoader JavaScriptCore context. " +
            "The Minecraft Script API must be imported by Minecraft-hosted behavior-pack scripts; " +
            "3105 loader scripts run in a separate context."
        );
    } else {
        try {
            if (typeof world.getDimension !== "function") {
                throw new Error("world.getDimension is not a function");
            }
            var dimension = world.getDimension("overworld");
            if (!dimension || typeof dimension.getEntities !== "function") {
                throw new Error("overworld dimension does not expose getEntities()");
            }
            var entities = dimension.getEntities();
            if (!entities || typeof entities.length !== "number" ||
                !isFinite(entities.length) || entities.length < 0 ||
                Math.floor(entities.length) !== entities.length) {
                throw new Error("dimension.getEntities() returned a non-array result");
            }
            entityCount = entities.length;
            apiStatus = "available";
        } catch (error) {
            apiStatus = "error";
            var errorText = error && error.stack
                ? String(error.stack)
                : String(error && error.message ? error.message : error);
            errors.push("Minecraft Script API probe failed: " + errorText);
        }
    }

    var report = {
        schemaVersion: 1,
        source: "ClientLoader 3105 Minecraft API diagnostic",
        capturedAt: new Date().toISOString(),
        clientLoader: {
            status: probes.clientMenuBridge ? "running" : "unavailable",
            script: "minecraft_api_3105_diagnostic.js"
        },
        "3105": {
            status: probes.clientMenuBridge ? "script_executed" : "unavailable",
            installedScriptExecuted: true
        },
        minecraftScriptAPI: {
            status: apiStatus,
            probes: probes,
            entityQuery: {
                status: entityCount === null ? "not_run" : "succeeded",
                entityCount: entityCount
            }
        },
        errors: errors
    };

    var reportPath = null;
    var bridgeMode = "unavailable";
    if (probes.clientMenuBridge &&
        typeof ClientMenu.reportRuntimeStatus === "function") {
        try {
            bridgeMode = "native_report_api";
            reportPath = ClientMenu.reportRuntimeStatus(
                JSON.stringify(report, null, 2),
                "MinecraftAPIDiagnostic.json"
            );
            if (!reportPath) {
                errors.push("Native report bridge did not return a saved report path.");
            }
        } catch (error) {
            errors.push("Native report bridge failed: " +
                String(error && error.stack ? error.stack : error));
        }
    }

    if (!reportPath && probes.clientMenuBridge &&
        typeof ClientMenu.exportJSON === "function") {
        try {
            bridgeMode = "legacy_export_json";
            report.nativeBridge = {
                status: "native_report_api_unavailable_or_failed",
                fallback: "ClientMenu.exportJSON",
                errors: errors.slice()
            };
            reportPath = ClientMenu.exportJSON(
                JSON.stringify(report, null, 2),
                "MinecraftAPIDiagnostic.json"
            );
        } catch (error) {
            errors.push("Legacy JSON export bridge failed: " +
                String(error && error.stack ? error.stack : error));
        }
    }

    if (reportPath && bridgeMode === "legacy_export_json") {
        var legacyMessage = apiStatus === "available"
            ? "3105-installed diagnostic ran and the Minecraft Script API entity query succeeded."
            : "3105-installed diagnostic ran, but the Minecraft Script API is " +
              apiStatus + ". Full errors: " + reportPath;
        if (typeof ClientMenu.notify === "function") {
            ClientMenu.notify(legacyMessage);
        }
    } else if (!reportPath) {
        console.error(
            "ClientLoader report bridge unavailable or failed; diagnostic report follows:",
            JSON.stringify(report, null, 2)
        );
    }
}());
