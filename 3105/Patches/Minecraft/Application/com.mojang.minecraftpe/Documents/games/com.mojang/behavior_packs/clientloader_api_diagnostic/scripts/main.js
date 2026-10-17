import { world, system } from "@minecraft/server";

const MESSAGE_PREFIX = "§d[ClientLoader API fallback]§r ";
const MAX_MESSAGE_LENGTH = 220;

function errorText(error) {
  if (error && typeof error.stack === "string" && error.stack.length > 0) {
    return error.stack;
  }
  if (error && typeof error.message === "string") {
    return error.message;
  }
  return String(error);
}

function sendLongMessage(player, message) {
  const text = String(message);
  for (let offset = 0; offset < text.length; offset += MAX_MESSAGE_LENGTH) {
    player.sendMessage(MESSAGE_PREFIX + text.slice(offset, offset + MAX_MESSAGE_LENGTH));
  }
}

function probeMinecraftScriptAPI() {
  try {
    const dimension = world.getDimension("overworld");
    const entities = dimension.getEntities();
    if (!Array.isArray(entities)) {
      throw new TypeError("Dimension.getEntities() did not return an array.");
    }
    return { available: true, entityCount: entities.length, errors: [] };
  } catch (error) {
    return { available: false, entityCount: null, errors: [errorText(error)] };
  }
}

world.afterEvents.playerSpawn.subscribe(({ player }) => {
  system.run(() => {
    const result = probeMinecraftScriptAPI();
    if (result.available) {
      player.sendMessage(
        MESSAGE_PREFIX +
        `Minecraft Script API query succeeded; overworld entities: ${result.entityCount}.`
      );
      player.sendMessage(
        MESSAGE_PREFIX +
        "This proves the behavior-pack API only; ClientLoader bridge status is separate."
      );
      return;
    }

    player.sendMessage(
      MESSAGE_PREFIX +
      "Minecraft Script API entity query failed. Full error follows in chat:"
    );
    for (const error of result.errors) {
      sendLongMessage(player, error);
    }
    player.sendMessage(
      MESSAGE_PREFIX +
      "If this pack fails to load before startup, check Minecraft's content log; " +
      "the import/module error happens before this script can catch it."
    );
  });
});
