(function () {
    "use strict";

    var errors = [];
    var limitations = [];
    var probes = {
        clientMenuBridge: typeof ClientMenu !== "undefined",
        minecraftWorldGlobal: typeof world !== "undefined",
        minecraftSystemGlobal: typeof system !== "undefined"
    };
    var apiStatus = "not_exposed_in_clientloader_context";
    var entityCount = null;

    if (!probes.clientMenuBridge) {
        errors.push("ClientMenu bridge is unavailable; ClientLoader did not inject its script API.");
    }

    if (!probes.minecraftWorldGlobal) {
        limitations.push(
            "This probe runs in ClientLoader's JavaScriptCore context, not a Minecraft behavior-pack module. " +
            "It cannot resolve import { world, system } from '@minecraft/server'; " +
            "the behavior-pack fallback result is not reported to this file."
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
            installedScriptExecuted: true,
            installationMethod: "ClientLoader evaluated this script from Documents/ClientLoader/scripts",
            installerApplicationStatus: "not_independently_verified"
        },
        minecraftScriptAPI: {
            status: apiStatus,
            scope: "ClientLoader JavaScriptCore context only",
            probes: probes,
            behaviorPackFallback: "not_reported_by_this_runtime",
            entityQuery: {
                status: entityCount === null ? "not_run" : "succeeded",
                entityCount: entityCount
            }
        },
        limitations: limitations,
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
            ? "ClientLoader's diagnostic entity query succeeded."
            : (apiStatus === "not_exposed_in_clientloader_context"
                ? "ClientLoader's diagnostic script ran. This check does not test Minecraft's behavior-pack API. Report: " +
                  reportPath
                : "ClientLoader's entity query returned " + apiStatus +
                  ". Full report: " + reportPath);
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
