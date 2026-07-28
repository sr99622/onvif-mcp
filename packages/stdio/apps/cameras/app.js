const list = document.querySelector("#camera-list");
const player = document.querySelector("#player");
const cameraName = document.querySelector("#camera-name");
const cameraAddress = document.querySelector("#camera-address");
const status = document.querySelector("#status");

let cameras = [];
let selectedIndex = -1;

function selectCamera(index) {
  if (!cameras.length) return;

  selectedIndex = (index + cameras.length) % cameras.length;
  const camera = cameras[selectedIndex];

  player.src = camera.media_player_url;
  cameraName.textContent = camera.hostname;
  cameraAddress.textContent = `${camera.ip_address} · ${camera.manufacturer} ${camera.model}`;
  status.textContent = `${cameras.length} cameras available`;

  document.querySelectorAll(".camera-button").forEach((button, buttonIndex) => {
    button.classList.toggle("active", buttonIndex === selectedIndex);
    button.setAttribute("aria-current", buttonIndex === selectedIndex ? "true" : "false");
  });

  localStorage.setItem("camera-switchboard:last-camera", camera.hostname);
}

async function initialize() {
  try {
    const response = await fetch("/outputs/camera_registry.json", { cache: "no-store" });
    if (!response.ok) throw new Error(`Registry request failed: ${response.status}`);

    const registry = await response.json();
    cameras = registry.cameras.filter((camera) => camera.media_player_url);

    cameras.forEach((camera, index) => {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "camera-button";
      button.textContent = camera.hostname;
      button.addEventListener("click", () => selectCamera(index));
      list.appendChild(button);
    });

    const savedName = localStorage.getItem("camera-switchboard:last-camera");
    const savedIndex = cameras.findIndex((camera) => camera.hostname === savedName);
    selectCamera(savedIndex >= 0 ? savedIndex : 0);
  } catch (error) {
    status.textContent = "Unable to load camera registry";
    cameraName.textContent = "Dashboard unavailable";
    cameraAddress.textContent = error.message;
  }
}

initialize();
