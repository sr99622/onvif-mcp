const STORAGE_KEY = "camera-multiview:selected-cameras";
const controls = [...document.querySelectorAll(".camera-control")];
const tiles = [...document.querySelectorAll(".camera-tile")];
const status = document.querySelector("#status");

let cameras = [];
let selections = [];

function saveSelections() {
  const hostnames = selections.map((index) => cameras[index]?.hostname ?? null);
  localStorage.setItem(STORAGE_KEY, JSON.stringify(hostnames));
}

function loadSavedSelections() {
  try {
    const saved = JSON.parse(localStorage.getItem(STORAGE_KEY));
    if (!Array.isArray(saved)) return [];
    return saved.map((hostname) => cameras.findIndex((camera) => camera.hostname === hostname));
  } catch {
    return [];
  }
}

function selectCamera(slot, cameraIndex) {
  const tile = tiles[slot];
  const control = controls[slot];
  const camera = cameras[cameraIndex];
  if (!tile || !control || !camera) return;

  selections[slot] = cameraIndex;
  control.querySelector("select").value = String(cameraIndex);
  tile.querySelector("h2").textContent = camera.hostname;
  control.querySelector(".camera-details").textContent =
    `${camera.ip_address} | ${camera.manufacturer} ${camera.model}`;

  const player = tile.querySelector("iframe");
  const streamUrl = camera.substream_player_url ?? camera.media_player_url;
  if (player.src !== streamUrl) {
    player.src = streamUrl;
  }

  saveSelections();
}

function populateControl(control, slot) {
  const select = control.querySelector("select");

  cameras.forEach((camera, index) => {
    const option = document.createElement("option");
    option.value = String(index);
    option.textContent = camera.hostname;
    select.appendChild(option);
  });

  select.addEventListener("change", () => selectCamera(slot, Number(select.value)));
}

async function initialize() {
  try {
    const response = await fetch("/outputs/camera_registry.json", { cache: "no-store" });
    if (!response.ok) throw new Error(`Registry request failed: ${response.status}`);

    const registry = await response.json();
    cameras = registry.cameras.filter((camera) => camera.media_player_url);
    if (!cameras.length) throw new Error("No camera streams are configured");

    controls.forEach(populateControl);

    const saved = loadSavedSelections();
    selections = controls.map((_, slot) => {
      const savedIndex = saved[slot];
      return savedIndex >= 0 ? savedIndex : slot % cameras.length;
    });

    selections.forEach((cameraIndex, slot) => selectCamera(slot, cameraIndex));
    status.textContent = `${cameras.length} cameras available`;
  } catch (error) {
    status.textContent = "Unable to load camera registry";
    controls.forEach((control, slot) => {
      const tile = tiles[slot];
      tile.querySelector("h2").textContent = "Stream unavailable";
      control.querySelector(".camera-details").textContent = error.message;
      control.querySelector("select").disabled = true;
    });
  }
}

initialize();
