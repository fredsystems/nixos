# Frigate's cameras in Home Assistant: their areas, and which of their
# entities stay enabled. Plan 06, Phase 3.
#
# The Frigate integration makes about 44 entities per camera: a count, an
# active count, an occupancy and a last-seen image per tracked object, plus
# tuning numbers and AI-description switches. Only the set below is kept
# (owner, 2026-11-26); the reconciler disables the rest, which takes them out
# of the UI and the recorder. Add an entity here to bring it back.
#
# Kept per camera: the camera; person occupancy and motion; review status;
# the last-person image; and the switches house mode drives (detect,
# recordings, snapshots, motion, review alerts and detections). Indoor
# cameras also keep dog and cat occupancy.
#
# Frigate's devices are identified by its config entry ID, which exists only
# once Home Assistant creates the entry, hence `{entry:frigate}`.
{
  config,
  inputs,
  lib,
  ...
}:
let
  frigate = inputs.self.nixosConfigurations.nvrhub.config.services.frigate.settings;

  areas = {
    doorbell = "Front Porch";
    front_door = "Front Porch";
    inside_garage = "Garage";
    kitchen = "Kitchen";
    living_room = "Living Room";
    office = "Office";
    upstairs_hall = "Upstairs Hallway";
  };

  # nvrhub's frigate.nix gives exactly the indoor cameras their own
  # objects.track (person, dog, cat).
  indoor = name: (frigate.cameras.${name}.objects or { }) ? track;

  keep =
    name:
    [
      "camera.${name}"
      "binary_sensor.${name}_person_occupancy"
      "binary_sensor.${name}_motion"
      "sensor.${name}_review_status"
      "image.${name}_person"
    ]
    ++ map (s: "switch.${name}_${s}") [
      "detect"
      "recordings"
      "snapshots"
      "motion"
      "review_alerts"
      "review_detections"
    ]
    ++ lib.optionals (indoor name) [
      "binary_sensor.${name}_dog_occupancy"
      "binary_sensor.${name}_cat_occupancy"
    ];
in
{
  services.home-assistant-reconciler = {
    devices = lib.mapAttrsToList (name: area: {
      identifier = [
        "frigate"
        "{entry:frigate}:${name}"
      ];
      inherit area;
      keepEntities = keep name;
    }) areas;

    # No Z-Wave device there yet, so ./devices.nix does not place it.
    floors.Downstairs.areas = [ "Garage" ];
  };

  assertions = [
    {
      assertion = lib.attrNames areas == lib.attrNames frigate.cameras;
      message = ''
        corehub: cameras.nix places ${toString (lib.attrNames areas)}, but nvrhub's
        Frigate has ${toString (lib.attrNames frigate.cameras)}. Give each camera
        an area here.
      '';
    }
    {
      assertion = lib.all (a: lib.elem a config.services.home-assistant-reconciler.areas) (
        lib.attrValues areas
      );
      message = "corehub: a camera's area in cameras.nix is not a declared area.";
    }
  ];
}
