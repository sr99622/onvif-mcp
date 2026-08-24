"""Canonical, human-editable MCP guidance for shared ONVIF tools.

Edit the descriptions in this file when field experience reveals better
instructions, warnings, examples, or argument guidance. Both the stdio and
HTTP transports register their shared tools with these exact descriptions.
"""

from textwrap import dedent


TOOL_GUIDANCE: dict[str, str] = {
    "change_camera_hostname": dedent(
        """\
        Change the hostname of a camera by IP address.

        This function queries the camera directly via ONVIF using its IP address
        (with credentials from environment variables), builds a full Camera object,
        and pushes the new hostname. No JSON string payload is needed — just the
        camera's IP and the desired hostname.

        Args:
            ip_address: The IP address of the camera to re-name.
            new_hostname: The new hostname to set.

        Returns:
            A message indicating success or failure
        """
    ).rstrip("\n"),

    "create_camera_preset_tour": dedent(
        """\
        Create a new, empty PTZ preset tour on a camera.

        This function queries the camera directly via ONVIF using its IP
        address (with credentials from environment variables), builds a full
        Camera object, and pushes the creation. No JSON payload is needed -
        just the camera's IP address.

        The underlying ONVIF CreatePresetTour operation has no name field, so
        if tour_name is given, this tool creates the tour first, determines
        the token the camera just assigned (by diffing the tour list
        before/after), then applies the name in a follow-up call - the tour
        has no spots yet either way, so this is a safe two-step sequence, the
        same pattern used by set_camera_preset for naming a newly-created
        preset.

        Once created, use set_camera_preset_tour to populate it with spots
        (preset token + stay time pairs), then start_camera_preset_tour to
        run it.

        Args:
            ip_address: The IP address of the camera to command.
            profile_token: The media profile token to command (almost always
                           the main profile, e.g. profiles[0].token).
            tour_name: Optional name to assign to the new tour.

        Returns:
            A message indicating success or failure. On success, includes the
            newly assigned tour token.
        """
    ).rstrip("\n"),

    "get_adapters": dedent(
        """\
        Return a list of available active network adapters on the server.

        Returns:
            A delimited string containing the IP address of each active adapter,
            one per line, separated by "\n--\n".
        """
    ).rstrip("\n"),

    "get_cameras_by_adapter": dedent(
        """\
        Discover cameras on a specific adapter subnet and return lightweight summaries.

        Args:
            adapter_ip: The IP address of the adapter to discover cameras on.

        Returns:
            A delimited string containing a summary dict for each camera found on
            the specified adapter subnet. Each camera's summary is separated by a line
            containing `--`.
        """
    ).rstrip("\n"),

    "get_camera": dedent(
        """\
        Get full detailed ONVIF information about a camera at the specified IP address.
        Please note that this tool is not needed for most tools in this server. Use
        this tool only if the needed data is not included in the camera summary 
        returned by get_cameras.

        Args:
            ip_address: The IP address of the camera to retrieve.

        Returns:
            A string representation of the camera's information.
        """
    ).rstrip("\n"),

    "get_cameras": dedent(
        """\
        Discover cameras on the local network and returns a delimited string
        containing lightweight summaries of the cameras data. The summaries
        returned by this tool should be kept in the session context for use
        in calling other tools in the server.

        This tool iterates through each activate network interface adapter and
        concatenates the summaries for all cameras found on all connected 
        networks.

        Each camera summary contains the most important fields an agent typically 
        needs to manage cameras and streams — hostname, serial number, 
        profiles, encoder config, PTZ presets, tours, snapshot & stream URIs, 
        web player URLs, and time offset. If full ONVIF data is needed, the
        get_camera tool can be used on a per camera basis.

        Returns:
            A delimited string containing summary dicts for each camera found on
            the local network. Each camera summary is separated by a line
            containing `--`.
        """
    ).rstrip("\n"),

    "get_web_player_url": dedent(
        """\
        Get the web player URL for a camera live stream. The url is suitable
        for playing the camera live stream in a browser window.

        Builds the URL using the camera's serial number and a media profile token.
        Note that the web player URL for each profile is also included directly in
        the camera summary returned by get_cameras, so this tool is only needed if
        the summary was not kept in context.

        Args:
            serial_number: The camera serial number found in the summary data of the 
                           camera returned by the get_cameras tool.
            profile_token: The media profile token found in the sunnary data of the 
                           camera returned by the get_cameras tool. The camera 
                           summary data includes a profile dict. The default choice
                           should be the first profile. The token is a field in the
                           profile dict.

        Returns:
            The web-player URL for the requested camera and media profile.
        """
    ).rstrip("\n"),

    "goto_camera_preset": dedent(
        """\
        Move a PTZ camera to one of its stored presets.

        These four values come from the abbreviated per-camera summary
        produced by get_cameras (NOT the full camera representation):
          camera_ptz_xaddr    <- that camera's ptz_xaddr
          camera_time_offset  <- that camera's time_offset
          camera_profile_token <- almost always the main profile's token,
                                  e.g. profiles[0].token, such as
                                  "MediaProfile000"
          camera_preset_token <- the token of the desired entry in that
                                 camera's ptz_presets list

        Credentials come from the CAMERA_USERNAME/CAMERA_PASSWORD environment
        variables, not from any of these arguments.

        This tool only sends the move command; it does not wait for the
        camera to finish moving or confirm it arrived. To check on that, call
        get_cameras again afterward and look at that camera's ptz_status
        field ("IDLE" once the move has completed).

        Args:
            camera_ptz_xaddr: That camera's ptz_xaddr, from get_cameras.
            camera_profile_token: The media profile token to command (almost
                           always the main profile, e.g. profiles[0].token).
            camera_preset_token: The token of the preset to move to, from
                           that camera's ptz_presets in get_cameras.
            camera_time_offset: That camera's time_offset (an integer number
                           of seconds), from get_cameras.

        Returns:
            A message indicating success or failure
        """
    ).rstrip("\n"),

    "pan_tilt_camera": dedent(
        """\
        Start a continuous pan/tilt move on a PTZ camera.

        These three values come from the abbreviated per-camera summary
        produced by get_cameras (NOT the full camera representation):
          camera_ptz_xaddr    <- that camera's ptz_xaddr
          camera_time_offset  <- that camera's time_offset
          camera_profile_token <- almost always the main profile's token,
                                  e.g. profiles[0].token, such as
                                  "MediaProfile000"

        Credentials come from the CAMERA_USERNAME/CAMERA_PASSWORD environment
        variables, not from any of these arguments.

        x and y are normalized velocities in the range -1.0 to 1.0 (0.0 means
        no motion on that axis): positive x pans right, negative x pans left;
        positive y tilts up, negative y tilts down. These are velocities, not
        positions - the camera keeps moving in that direction at that speed
        until stop_camera_pan_tilt is called.

        This does not stop on its own except at the camera's physical pan/tilt
        limits - most PTZ hardware halts at its mechanical range ends, so
        forgetting to stop is not unsafe, but the camera will simply drift to
        whichever limit it's heading toward and park there rather than stopping
        at a precise point. Call stop_camera_pan_tilt to halt motion exactly
        where you want it, or check that camera's ptz_status field via a fresh
        get_cameras call to see where it ended up.

        This is pan/tilt only - it has no effect on zoom. Use zoom_camera
        separately for zoom; a camera can only perform one of pan/tilt or zoom
        at a time.

        Args:
            camera_ptz_xaddr: That camera's ptz_xaddr, from get_cameras.
            camera_profile_token: The media profile token to command (almost
                           always the main profile, e.g. profiles[0].token).
            camera_time_offset: That camera's time_offset (an integer number
                           of seconds), from get_cameras.
            x: Pan velocity, -1.0 (left) to 1.0 (right). 0.0 for no pan.
            y: Tilt velocity, -1.0 (down) to 1.0 (up). 0.0 for no tilt.

        Returns:
            A message indicating success or failure
        """
    ).rstrip("\n"),

    "reboot_camera": dedent(
        """\
        Reboot a camera using the ONVIF SystemReboot operation.

        This function queries the camera directly via ONVIF using its IP address
        (with credentials from environment variables), builds a full Camera object,
        and requests a reboot. No JSON payload is needed.

        The camera will normally be unreachable for a short period after accepting
        the request. A successful response confirms that the reboot request was
        accepted, not that the camera has finished restarting.

        Args:
            ip_address: The IP address of the camera to reboot.

        Returns:
            A message indicating whether the reboot request succeeded or failed.
        """
    ).rstrip("\n"),

    "remove_camera_preset": dedent(
        """\
        Permanently delete a PTZ preset from a camera.

        This function queries the camera directly via ONVIF using its IP
        address (with credentials from environment variables), builds a full
        Camera object, and pushes the removal. No JSON payload is needed -
        just the camera's IP address.

        This removes the preset entirely - it is not the same as clearing or
        resetting a preset's position, and it cannot be undone from this
        tool. If you want to reuse a preset's token/slot for a different
        position instead of deleting it outright, use set_camera_preset in
        overwrite mode instead.

        Args:
            ip_address: The IP address of the camera to command.
            profile_token: The media profile token to command (almost always
                           the main profile, e.g. profiles[0].token).
            preset_token: Token of the preset to remove (from get_cameras'
                          ptz_presets).

        Returns:
            A message indicating success or failure
        """
    ).rstrip("\n"),

    "remove_camera_preset_tour": dedent(
        """\
        Permanently delete a PTZ preset tour from a camera.

        This function queries the camera directly via ONVIF using its IP
        address (with credentials from environment variables), builds a full
        Camera object, and pushes the removal. No JSON payload is needed -
        just the camera's IP address.

        This removes the tour entirely - it does not affect the individual
        presets used in its spots, only the tour itself - and cannot be
        undone from this tool.

        Args:
            ip_address: The IP address of the camera to command.
            profile_token: The media profile token to command (almost always
                           the main profile, e.g. profiles[0].token).
            tour_token: Token of the tour to remove (from get_cameras'
                        ptz_tours).

        Returns:
            A message indicating success or failure
        """
    ).rstrip("\n"),

    "set_camera_audio_encoding": dedent(
        """\
        Set the audio encoding for one media profile on a camera.

        This function queries the camera directly via ONVIF using its IP
        address (with credentials from environment variables), builds a full
        Camera object, sets the encoding on that profile's audio_encoder,
        then pushes the whole encoder configuration back to the camera in one
        ONVIF call. No JSON payload is needed - just the camera's IP address.

        Args:
            ip_address: The IP address of the camera to command.
            profile_token: The media profile token whose audio_encoder should
                           be pushed to the camera.
            encoding: The codec name, e.g. "G711" or "AAC". Must match one of
                        the codecs the camera actually offers for this
                        profile.

        Returns:
            A message indicating success or failure
        """
    ).rstrip("\n"),

    "set_camera_audio_sample_rate": dedent(
        """\
        Set the audio sample rate for one media profile on a camera.

        This function queries the camera directly via ONVIF using its IP
        address (with credentials from environment variables), builds a full
        Camera object, sets the sample rate on that profile's audio_encoder,
        then pushes the whole encoder configuration back to the camera in one
        ONVIF call. No JSON payload is needed - just the camera's IP address.

        Note: on at least some hardware (observed on an Amcrest G711
        implementation), bitrate and sample_rate appear to be coupled -
        changing bitrate alone was silently ignored by the camera, while
        changing sample_rate caused bitrate to change along with it. Verify
        the result with a fresh get_cameras call afterward, since a "success"
        response does not guarantee the change was actually applied as
        requested.

        Args:
            ip_address: The IP address of the camera to command.
            profile_token: The media profile token whose audio_encoder should
                           be pushed to the camera.
            sample_rate: Integer sample rate. Must be one of the values the
                        camera actually offers for this profile's current
                        encoding.

        Returns:
            A message indicating success or failure
        """
    ).rstrip("\n"),

    "set_camera_preset": dedent(
        """\
        Create a new PTZ preset, or overwrite an existing one with the camera's
        current position.

        This function queries the camera directly via ONVIF using its IP
        address (with credentials from environment variables), builds a full
        Camera object, and edits it before pushing. No JSON payload is
        needed - just the camera's IP address.

        Two modes, based on whether preset_token is supplied:

        - preset_token omitted (create mode): the camera creates a brand new
          preset at its current position. Cameras support a limited number of
          presets - check how many already exist (e.g. via get_cameras'
          ptz_presets) before creating another, in case the camera silently
          rejects it once full. If preset_name is given, the new preset is
          created first, then renamed in a second call - the underlying ONVIF
          operation can't assign a name to a preset that doesn't have a token
          yet, so this tool creates it unnamed, determines the token the
          camera just assigned, then renames it. The camera doesn't move
          between these two calls, so the rename call safely re-saves the
          same position.

        - preset_token supplied (overwrite mode): the preset matching that
          token has its position overwritten to the camera's CURRENT
          position - not restored to wherever it used to point. If you only
          want to rename an existing preset without moving it, first call
          goto_camera_preset to move the camera back to that preset's own
          position, THEN call this tool - otherwise the preset's saved
          position will be silently replaced with wherever the camera
          happens to be sitting right now. Pass preset_name to also update
          the preset's stored name at the same time.

        Args:
            ip_address: The IP address of the camera to command.
            profile_token: The media profile token to command (almost always
                           the main profile, e.g. profiles[0].token).
            preset_token: Token of an existing preset to overwrite (from
                          get_cameras' ptz_presets). Omit to create a new
                          preset instead.
            preset_name: Optional name to assign to the preset (new or
                         existing).

        Returns:
            A message indicating success or failure. On successful creation,
            includes the newly assigned preset token.
        """
    ).rstrip("\n"),

    "set_camera_preset_tour": dedent(
        """\
        Update a PTZ preset tour's name, auto_start, and/or spots on a camera.

        This function queries the camera directly via ONVIF using its IP
        address (with credentials from environment variables), builds a full
        Camera object, applies whichever of tour_name/auto_start/spots you
        supplied, then pushes the whole tour configuration in a single ONVIF
        call. Arguments left as None (the default) keep the tour's current
        value for that field - only supply the ones you actually want to
        change. No JSON payload is needed - just the camera's IP address.

        Args:
            ip_address: The IP address of the camera to command.
            profile_token: The media profile token to command (almost always
                           the main profile, e.g. profiles[0].token).
            tour_token: The token of the tour to update (from get_cameras'
                        ptz_tours).
            tour_name: Optional new display name for the tour.
            auto_start: Optional new value for whether the tour starts
                        automatically under the camera's own configured
                        starting condition, rather than needing to be started
                        manually via start_camera_preset_tour.
            spots: Optional new list of stops for the tour, REPLACING its
                   entire current spot list (not additive) - to add or remove
                   a single spot, supply the full desired end-result list.
                   Each entry is a dict with:
                     preset_token: must match a real preset (from
                                   get_cameras' ptz_presets).
                     stay_time: an ISO 8601 duration string (e.g. "PT5S" for
                                5 seconds).
                   e.g. [{"preset_token": "1", "stay_time": "PT5S"}, ...]

        Returns:
            A message indicating success or failure
        """
    ).rstrip("\n"),

    "set_camera_video_bitrate": dedent(
        """\
        Set the video bitrate limit for one media profile on a camera.

        This function queries the camera directly via ONVIF using its IP
        address (with credentials from environment variables), builds a full
        Camera object, sets the bitrate limit on that profile's
        video_encoder.rate_control, then pushes the whole encoder
        configuration back to the camera in one ONVIF call. No JSON payload
        is needed - just the camera's IP address.

        Args:
            ip_address: The IP address of the camera to command.
            profile_token: The media profile token whose video_encoder should
                           be pushed to the camera.
            bitrate_limit: Integer kilobits per second. Must fall within the
                        camera-reported valid bitrate range for this
                        profile's current encoding.

        Returns:
            A message indicating success or failure
        """
    ).rstrip("\n"),

    "set_camera_video_frame_rate": dedent(
        """\
        Set the video frame rate limit for one media profile on a camera.

        This function queries the camera directly via ONVIF using its IP
        address (with credentials from environment variables), builds a full
        Camera object, sets the frame rate limit on that profile's
        video_encoder.rate_control, then pushes the whole encoder
        configuration back to the camera in one ONVIF call. No JSON payload
        is needed - just the camera's IP address.

        Args:
            ip_address: The IP address of the camera to command.
            profile_token: The media profile token whose video_encoder should
                           be pushed to the camera.
            frame_rate_limit: Integer frames per second. Must fall within the
                        camera-reported valid frame rate range for this
                        profile's current encoding.

        Returns:
            A message indicating success or failure
        """
    ).rstrip("\n"),

    "set_camera_video_gov_length": dedent(
        """\
        Set the video gov_length for one media profile on a camera.

        This function queries the camera directly via ONVIF using its IP
        address (with credentials from environment variables), builds a full
        Camera object, sets the gov_length on that profile's
        video_encoder, then pushes the whole encoder
        configuration back to the camera in one ONVIF call. No JSON payload
        is needed - just the camera's IP address.

        Args:
            ip_address: The IP address of the camera to command.
            profile_token: The media profile token whose video_encoder should
                           be pushed to the camera.
            gov_length: Integer gov_length. Must fall within the
                        camera-reported valid gov length range for this
                        profile's current encoding.

        Returns:
            A message indicating success or failure
        """
    ).rstrip("\n"),

    "set_camera_video_resolution": dedent(
        """\
        Set the video resolution for one media profile on a camera.

        This function queries the camera directly via ONVIF using its IP
        address (with credentials from environment variables), builds a full
        Camera object, sets the resolution on that profile's video_encoder,
        then pushes the whole encoder configuration back to the camera in one
        ONVIF call. No JSON payload is needed - just the camera's IP address.

        Args:
            ip_address: The IP address of the camera to command.
            profile_token: The media profile token whose video_encoder should
                           be pushed to the camera.
            resolution: A string in the exact format f"{width} x {height}"
                        (e.g. "1920 x 1080") - the same format used in the
                        camera JSON representation. Must be one of the
                        camera-reported valid resolutions for this profile's
                        current encoding.

        Returns:
            A message indicating success or failure
        """
    ).rstrip("\n"),

    "start_camera_preset_tour": dedent(
        """\
        Start running a PTZ preset tour on a camera.

        IMPORTANT: to stop this tour later, stop_camera_preset_tour needs the
        EXACT SAME camera_ptz_xaddr, camera_profile_token, and
        camera_ptz_tour_token used here. The success message from this call
        echoes all four argument values back to you in plain text - copy them
        directly from that message into the matching stop_camera_preset_tour
        call rather than trying to recall or reconstruct them later. None of
        these values are read from the camera or validated against anything;
        if any is wrong or missing when stopping, the camera will reject the
        request with an error like "Profile token does not exist", which is
        NOT a sign of a timing, authentication, or clock-sync problem - it
        means one of these argument values was wrong on that call.

        These four values come from the abbreviated per-camera summary
        produced by get_cameras (NOT the full camera representation):
          camera_ptz_xaddr    <- that camera's ptz_xaddr
          camera_time_offset  <- that camera's time_offset
          camera_profile_token <- almost always the main profile's token,
                                  e.g. profiles[0].token, such as
                                  "MediaProfile000"
          camera_ptz_tour_token <- the token of the desired entry in that
                                   camera's ptz_tours list

        Credentials come from the CAMERA_USERNAME/CAMERA_PASSWORD environment
        variables, not from any of these arguments.

        The camera begins moving through the tour's spots in order, pausing
        at each for its configured stay_time, looping continuously until
        stop_camera_preset_tour is called. This does not wait for the tour to
        complete (it never does, on its own) or confirm it started - check
        that tour's status field via a fresh get_cameras call to see its
        reported state (e.g. "Idle" vs actively touring).

        Args:
            camera_ptz_xaddr: That camera's ptz_xaddr, from get_cameras.
            camera_profile_token: The media profile token to command (almost
                           always the main profile, e.g. profiles[0].token).
            camera_ptz_tour_token: Token of the tour to start, from that
                           camera's ptz_tours in get_cameras.
            camera_time_offset: That camera's time_offset (an integer number
                           of seconds), from get_cameras.

        Returns:
            A message indicating success or failure. On success, echoes back
            all four argument values for you to reuse in the matching
            stop_camera_preset_tour call.
        """
    ).rstrip("\n"),

    "stop_camera_pan_tilt": dedent(
        """\
        Stop an in-progress continuous pan/tilt move started by pan_tilt_camera.

        These three values must match what was used in the pan_tilt_camera
        call that started the move - they come from the abbreviated
        per-camera summary produced by get_cameras (NOT the full camera
        representation):
          camera_ptz_xaddr    <- that camera's ptz_xaddr
          camera_time_offset  <- that camera's time_offset
          camera_profile_token <- almost always the main profile's token,
                                  e.g. profiles[0].token, such as
                                  "MediaProfile000"

        Credentials come from the CAMERA_USERNAME/CAMERA_PASSWORD environment
        variables, not from any of these arguments.

        Has no effect on zoom - use stop_camera_zoom to stop a zoom move. If no
        pan/tilt move is currently in progress, this is a harmless no-op on
        most cameras.

        Args:
            camera_ptz_xaddr: That camera's ptz_xaddr, from get_cameras.
            camera_profile_token: The media profile token to command (should
                           match whatever was used in the pan_tilt_camera call).
            camera_time_offset: That camera's time_offset (an integer number
                           of seconds) - a fresh value from get_cameras is
                           fine here even if it differs slightly from the
                           value used when the move was started.

        Returns:
            A message indicating success or failure
        """
    ).rstrip("\n"),

    "stop_camera_preset_tour": dedent(
        """\
        Stop a running PTZ preset tour on a camera.

        IMPORTANT: camera_ptz_xaddr, camera_profile_token, and
        camera_ptz_tour_token here must be the EXACT SAME values used in the
        start_camera_preset_tour call that started this tour - that call's
        success message echoed all four values back to you in plain text
        specifically so you could copy them directly into this call. None of
        these values are read from the camera or validated against anything -
        if any is wrong, missing, or reconstructed from memory incorrectly,
        the camera will reject this request with an error like "Profile
        token does not exist". That error means one of these argument values
        was wrong on THIS call - it is NOT a sign of a timing, authentication,
        or clock-sync problem, and re-syncing time or fetching a fresher
        camera JSON will not fix it. If you no longer have the exact values
        from when the tour was started, get camera_profile_token from that
        camera's profiles[0].token and camera_ptz_tour_token by matching the
        tour's name in a fresh get_cameras call.

        Credentials come from the CAMERA_USERNAME/CAMERA_PASSWORD environment
        variables, not from any of these arguments.

        Args:
            camera_ptz_xaddr: Must exactly match the value used in the
                           start_camera_preset_tour call for this tour.
            camera_profile_token: Must exactly match the value used in the
                           start_camera_preset_tour call for this tour.
            camera_ptz_tour_token: Must exactly match the value used in the
                           start_camera_preset_tour call for this tour.
            camera_time_offset: That camera's time_offset (an integer number
                           of seconds) - a fresh value from get_cameras is
                           fine here even if it differs slightly from the
                           value used at start time.

        Returns:
            A message indicating success or failure
        """
    ).rstrip("\n"),

    "stop_camera_zoom": dedent(
        """\
        Stop an in-progress continuous zoom move started by zoom_camera.

        These three values must match what was used in the zoom_camera call
        that started the move - they come from the abbreviated per-camera
        summary produced by get_cameras (NOT the full camera representation):
          camera_ptz_xaddr    <- that camera's ptz_xaddr
          camera_time_offset  <- that camera's time_offset
          camera_profile_token <- almost always the main profile's token,
                                  e.g. profiles[0].token, such as
                                  "MediaProfile000"

        Credentials come from the CAMERA_USERNAME/CAMERA_PASSWORD environment
        variables, not from any of these arguments.

        Has no effect on pan/tilt - use stop_camera_pan_tilt to stop a pan/tilt
        move. If no zoom move is currently in progress, this is a harmless
        no-op on most cameras.

        Args:
            camera_ptz_xaddr: That camera's ptz_xaddr, from get_cameras.
            camera_profile_token: The media profile token to command (should
                           match whatever was used in the zoom_camera call).
            camera_time_offset: That camera's time_offset (an integer number
                           of seconds) - a fresh value from get_cameras is
                           fine here even if it differs slightly from the
                           value used when the move was started.

        Returns:
            A message indicating success or failure
        """
    ).rstrip("\n"),

    "sync_camera_time": dedent(
        """\
        Synchronize a camera's clock to this machine's current local time.

        Useful for correcting a camera whose internal clock has drifted or
        reset (e.g. after a power loss reverting it to an epoch default like
        2000-01-01), which otherwise produces confusing timestamps on
        snapshots and event data.

        This function queries the camera directly via ONVIF using its IP address
        (with credentials from environment variables), builds a full Camera object,
        synchronizes its clock, then re-queries to report the resulting time offset.
        No JSON string payload is needed — just the camera's IP address.

        Args:
            ip_address: The IP address of the camera to sync.

        Returns:
            A message indicating success or failure, including the resulting
            time_offset in seconds if successful.

        Note: The returned time_offset value is used during ONVIF authentication.
        Callers should save this new time_offset into their local camera JSON
        summary (as returned by get_cameras) after a sync completes successfully,
        otherwise future ONVIF calls to this camera may fail with timestamp-based
        auth errors. The get_cameras tool reads time_offset from each discovered
        camera at discovery time, so the saved value will be used for the next
        sync_camera_time or other IP-address tool calls.
        """
    ).rstrip("\n"),

    "zoom_camera": dedent(
        """\
        Start a continuous zoom move on a PTZ camera.

        These three values come from the abbreviated per-camera summary
        produced by get_cameras (NOT the full camera representation):
          camera_ptz_xaddr    <- that camera's ptz_xaddr
          camera_time_offset  <- that camera's time_offset
          camera_profile_token <- almost always the main profile's token,
                                  e.g. profiles[0].token, such as
                                  "MediaProfile000"

        Credentials come from the CAMERA_USERNAME/CAMERA_PASSWORD environment
        variables, not from any of these arguments.

        z is a normalized velocity in the range -1.0 to 1.0, excluding 0.0:
        positive zooms in (telephoto), negative zooms out (wide). This is a
        velocity, not a position - the camera keeps zooming at that speed
        until stop_camera_zoom is called. z=0.0 is rejected here rather than
        silently doing nothing; use stop_camera_zoom if you want to halt an
        in-progress zoom.

        This does not stop on its own except at the camera's physical zoom
        limits (fully wide or fully telephoto) - most PTZ hardware halts
        there, so forgetting to stop is not unsafe, but the camera will simply
        zoom to whichever limit it's heading toward and stop there rather than
        at a precise point. Call stop_camera_zoom to halt zoom exactly where
        you want it, or check that camera's ptz_status field via a fresh
        get_cameras call to see where it ended up.

        This is zoom only - it has no effect on pan/tilt. Use pan_tilt_camera
        separately for pan/tilt; a camera can only perform one of pan/tilt or
        zoom at a time.

        Args:
            camera_ptz_xaddr: That camera's ptz_xaddr, from get_cameras.
            camera_profile_token: The media profile token to command (almost
                           always the main profile, e.g. profiles[0].token).
            camera_time_offset: That camera's time_offset (an integer number
                           of seconds), from get_cameras.
            z: Zoom velocity, -1.0 (zoom out) to 1.0 (zoom in). Must not be 0.0.

        Returns:
            A message indicating success or failure
        """
    ).rstrip("\n"),
}
