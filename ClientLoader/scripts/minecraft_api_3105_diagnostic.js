(function () {
    "use strict";

    var errors = [];
    var limitations = [];
    var hasClientMenu = typeof ClientMenu !== "undefined";

    if (!hasClientMenu) {
        errors.push("ClientMenu bridge is unavailable; ClientLoader did not inject its script API.");
    }
    limitations.push(
        "Minecraft's @minecraft/server ES module is provided by the game's scripting host. " +
        "ClientLoader's injected JavaScriptCore context has no Bedrock module resolver; " +
        "this diagnostic does not import or test the Minecraft API."
    );

    var report = {
        schemaVersion: 1,
        source: "ClientLoader 3105 script-runtime diagnostic",
        capturedAt: new Date().toISOString(),
        clientLoader: {
            status: hasClientMenu ? "running" : "unavailable",
            script: "minecraft_api_3105_diagnostic.js"
        },
        "3105": {
            status: hasClientMenu ? "script_executed" : "unavailable",
            installedScriptExecuted: true,
            installationMethod: "ClientLoader evaluated this script from Documents/ClientLoader/scripts",
            installerApplicationStatus: "not_independently_verified"
        },
        minecraftScriptAPI: {
            status: "not_tested",
            scope: "ClientLoader JavaScriptCore context only",
            importResolution: "not_supported_in_this_context",
            entityQuery: "not_run"
        },
        limitations: limitations,
        errors: errors
    };

    var reportPath = null;
    var bridgeMode = "unavailable";
    if (hasClientMenu &&
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

    if (!reportPath && hasClientMenu &&
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
        if (typeof ClientMenu.notify === "function") {
            ClientMenu.notify(
                "ClientLoader's script ran. Minecraft's @minecraft/server API was not tested by this check. Report: " +
                reportPath
            );
        }
    } else if (!reportPath) {
        console.error(
            "ClientLoader report bridge unavailable or failed; diagnostic report follows:",
            JSON.stringify(report, null, 2)
        );
    }
}());
