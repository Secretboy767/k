ClientMenu.registerFeature("Synthetic ESP test boxes", false, function (enabled) {
    ClientMenu.setSyntheticESPEnabled(enabled);
});

ClientMenu.registerAction("Export chunk data diagnostic", function () {
    var diagnostic = {
        schemaVersion: 1,
        exportedAt: new Date().toISOString(),
        captureStatus: "unavailable",
        message: "This loader script cannot read Minecraft's live world or current chunk.",
        source: "ClientLoader JavaScriptCore; no Minecraft world API is connected",
        currentChunk: null,
        blocks: {
            status: "not_captured",
            reason: "No live chunk/block API is available to this script."
        },
        entities: {
            status: "not_captured",
            reason: "No live entity/player API is available to this script."
        },
        syntheticOverlaySamples: [
            {
                type: "minecraft:cow",
                label: "TEST COW - NOT LIVE",
                bounds: { width: 0.9, height: 1.3 },
                source: "bundled vanilla definition; not read from the current world"
            },
            {
                type: "minecraft:player",
                label: "TEST PLAYER - NOT LIVE",
                bounds: { width: 0.6, height: 1.8 },
                source: "bundled vanilla definition; not read from the current world"
            }
        ]
    };
    var filePath = ClientMenu.exportJSON(
        JSON.stringify(diagnostic, null, 2),
        "ChunkCaptureDiagnostic.json"
    );
    if (filePath) {
        ClientMenu.notify(
            "Diagnostic saved (no live chunk data was captured):\n" + filePath
        );
    } else {
        ClientMenu.notify("Diagnostic export failed. Check ClientLoader.log for details.");
    }
});
