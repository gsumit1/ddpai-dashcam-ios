# Requirements Document

## Introduction

This document specifies the requirements for a DDPAI dash cam companion application for iOS. The application connects to a DDPAI dash camera, typically over the camera's own Wi-Fi hotspot, and provides three core capability groups: live preview of the camera feed, playback and download of recorded drives and emergency footage, and remote control of camera settings (video resolution, collision sensitivity, audio recording, and parking monitoring modes).

The application targets drivers who want to view, manage, and configure their DDPAI dash camera from their iPhone without removing the storage media from the device.

## Glossary

- **App**: The DDPAI dash cam companion application running on an iOS device.
- **Camera**: A DDPAI dash camera device that exposes a Wi-Fi hotspot and a control/streaming interface.
- **Connection_Manager**: The App subsystem responsible for discovering, connecting to, and monitoring the link to the Camera.
- **Live_Preview**: The App subsystem that renders the real-time video stream from the Camera.
- **Media_Browser**: The App subsystem that lists recorded clips stored on the Camera.
- **Media_Player**: The App subsystem that plays recorded clips.
- **Download_Manager**: The App subsystem that transfers clips from the Camera to local device storage.
- **Local_Library**: The collection of clips stored on the iOS device after download.
- **Settings_Controller**: The App subsystem that reads and writes Camera configuration values.
- **Normal_Clip**: A routine recording segment produced during continuous driving.
- **Event_Clip**: A protected recording triggered by a collision/G-sensor event, which is retained separately from Normal_Clips.
- **Emergency_Footage**: Event_Clips and manually locked clips that are protected from automatic overwrite.
- **G_Sensor**: The Camera accelerometer used to detect collisions and shocks.
- **Collision_Sensitivity**: The G_Sensor threshold level that determines when an Event_Clip is triggered.
- **Parking_Monitoring_Mode**: A Camera recording behavior active while the vehicle is parked (for example, motion detection, time-lapse, or disabled).
- **Wi-Fi_Hotspot**: The wireless network broadcast by the Camera that the iOS device joins to communicate with the Camera.
- **Connection_State**: The current status of the link between the App and the Camera (disconnected, connecting, connected, or interrupted).

## Requirements

### Requirement 1: Camera Discovery and Connection

**User Story:** As a driver, I want the App to discover and connect to my dash camera over its Wi-Fi hotspot, so that I can control the Camera from my iPhone.

#### Acceptance Criteria

1. WHEN the user opens the connection screen, THE Connection_Manager SHALL display the current Connection_State as one of: disconnected, connecting, connected, or interrupted.
2. WHEN the iOS device is joined to the Camera Wi-Fi_Hotspot and the user initiates a connection, THE Connection_Manager SHALL set the Connection_State to connecting and establish a session with the Camera within 10 seconds.
3. WHEN a session with the Camera is established, THE Connection_Manager SHALL set the Connection_State to connected and display the Camera model identifier.
4. IF the iOS device is not joined to the Camera Wi-Fi_Hotspot when the user initiates a connection, THEN THE Connection_Manager SHALL retain the Connection_State as disconnected and display an instruction directing the user to join the Camera Wi-Fi_Hotspot.
5. IF the connection attempt does not succeed within 10 seconds, THEN THE Connection_Manager SHALL set the Connection_State to disconnected and display a connection failure message indicating that the session could not be established.
6. IF the Camera responds during session establishment with a model identifier that is not supported by the App, THEN THE Connection_Manager SHALL set the Connection_State to disconnected and display an error message indicating that the connected Camera is not supported.
7. WHILE the Connection_State is connected, THE Connection_Manager SHALL detect loss of the Camera link within 5 seconds and set the Connection_State to interrupted.
8. WHEN the Connection_State changes to interrupted, THE App SHALL display a reconnection prompt and attempt to re-establish the session automatically up to 3 times, with each attempt timing out after 10 seconds.
9. IF all automatic reconnection attempts fail after the Connection_State becomes interrupted, THEN THE Connection_Manager SHALL set the Connection_State to disconnected and display a connection failure message indicating that the Camera link was lost.

### Requirement 2: Live Preview

**User Story:** As a driver, I want to watch a real-time feed from the connected Camera on my phone, so that I can verify framing and current recording.

#### Acceptance Criteria

1. WHILE the Connection_State is connected, THE Live_Preview SHALL render the real-time video stream from the Camera with an end-to-end latency not exceeding 2 seconds.
2. WHEN the user opens the Live_Preview and the Connection_State is connected, THE Live_Preview SHALL display the first video frame within 5 seconds.
3. WHILE the Live_Preview is rendering, THE Live_Preview SHALL display the live stream resolution and a connection signal indicator showing current link quality.
4. IF the Connection_State changes to interrupted or disconnected WHILE the Live_Preview is active, THEN THE Live_Preview SHALL stop rendering within 2 seconds and display a stream-unavailable message.
5. WHEN the user leaves the Live_Preview screen, THE Live_Preview SHALL stop requesting the real-time stream from the Camera.
6. WHERE the Camera reports that audio is available in the live stream, THE Live_Preview SHALL provide a control to mute and unmute live audio playback.
7. IF the first video frame does not display within 5 seconds of opening the Live_Preview, THEN THE Live_Preview SHALL display a stream-unavailable message and provide a retry control.

### Requirement 3: Browse Recorded Drives

**User Story:** As a driver, I want to view the list of recorded drives on the Camera, so that I can find footage I care about.

#### Acceptance Criteria

1. WHEN the user opens the Media_Browser and the Connection_State is connected, THE Media_Browser SHALL retrieve and display the list of clips stored on the Camera within 15 seconds of the browser opening.
2. WHILE a clip list retrieval is in progress, THE Media_Browser SHALL display a loading indicator until retrieval completes, fails, or the 15 second timeout elapses.
3. THE Media_Browser SHALL display, for each clip, the recording start timestamp, the clip duration expressed in hours, minutes, and seconds, the clip file size expressed in megabytes, and the clip type.
4. THE Media_Browser SHALL distinguish Normal_Clips from Event_Clips using a visible indicator rendered on each clip entry.
5. WHERE the user applies a clip-type filter, THE Media_Browser SHALL display only the clips whose type matches the selected filter and SHALL retain the descending recording-start-timestamp order of the matching clips.
6. WHERE the user applies a clip-type filter and no stored clips match the selected filter, THE Media_Browser SHALL display a no-matching-clips message.
7. THE Media_Browser SHALL order the displayed clips by recording start timestamp in descending order.
8. IF the Camera reports no stored clips, THEN THE Media_Browser SHALL display an empty-library message and SHALL display zero clip entries.
9. IF clip list retrieval does not complete within 15 seconds, THEN THE Media_Browser SHALL cancel the retrieval, display a retrieval failure message indicating the list could not be loaded, and provide a retry control that re-initiates retrieval when activated.
10. IF the Connection_State changes to disconnected during clip list retrieval, THEN THE Media_Browser SHALL stop the retrieval and display a connection-lost message with a retry control.

### Requirement 4: Playback of Recorded Clips

**User Story:** As a driver, I want to play recorded clips from the Camera, so that I can review footage before deciding to download it.

#### Acceptance Criteria

1. WHEN the user selects a clip from the Media_Browser, THE Media_Player SHALL begin playback of the selected clip within 3 seconds.
2. THE Media_Player SHALL provide play, pause, and seek controls during playback, with the seek control supporting positions from 0 to the total clip duration.
3. THE Media_Player SHALL display the current playback position and the total clip duration, each expressed in hours, minutes, and seconds.
4. IF playback cannot start within 10 seconds of selection, THEN THE Media_Player SHALL stop the playback attempt, display a playback failure message, and provide a retry control.
5. WHEN the user activates the retry control after a playback failure, THE Media_Player SHALL re-attempt playback of the selected clip.
6. WHEN the selected clip exists in the Local_Library, THE Media_Player SHALL play the clip from the Local_Library instead of streaming it from the Camera.
7. IF the selected clip does not exist in the Local_Library and the Connection_State is not connected, THEN THE Media_Player SHALL display a message indicating the clip is unavailable for playback.

### Requirement 5: Download Clips to the Device

**User Story:** As a driver, I want to download clips from the Camera to my phone, so that I can keep footage after disconnecting from the Camera.

#### Acceptance Criteria

1. WHEN the user requests download of a clip, THE Download_Manager SHALL transfer the selected clip from the Camera to the Local_Library.
2. WHILE a download is in progress, THE Download_Manager SHALL update the transferred percentage, as an integer value from 0 to 100, at an interval not exceeding 1 second.
3. WHEN a download completes, THE Download_Manager SHALL store the clip in the Local_Library and mark the clip as downloaded in the Media_Browser.
4. WHERE the user selects multiple clips for download, up to a maximum of 100 clips per request, THE Download_Manager SHALL queue the selected clips and process the queue sequentially in the order the clips were selected.
5. IF the Connection_State changes to interrupted or disconnected during a download, THEN THE Download_Manager SHALL mark the download as incomplete, retain the completed byte count for resuming, and display a status indication that the download was interrupted.
6. WHEN the user resumes an incomplete download and the Connection_State is connected, THE Download_Manager SHALL continue the transfer from the retained byte count.
7. IF the user resumes an incomplete download and the Connection_State is not connected, THEN THE Download_Manager SHALL keep the download marked as incomplete and display a status indication that the Camera is not connected.
8. IF available iOS device storage is less than the sum of the requested clip size and a 50 MB reserve margin, THEN THE Download_Manager SHALL cancel the download, retain any previously stored completed clips, and display an insufficient-storage message indicating the required and available storage amounts.
9. WHEN the user cancels an in-progress download, THE Download_Manager SHALL stop the transfer within 2 seconds and remove the partial clip data for the canceled clip from the Local_Library.

### Requirement 6: Emergency and Event Footage Handling

**User Story:** As a driver, I want to view and save emergency footage, so that I can preserve clips from collision events.

#### Acceptance Criteria

1. WHEN the Media_Browser displays clips, THE Media_Browser SHALL identify Emergency_Footage with a visible protected indicator that is observably distinct from the unprotected indicator.
2. WHERE the user requests the Emergency_Footage view, THE Media_Browser SHALL display only Event_Clips and manually locked clips and SHALL exclude unlocked Normal_Clips.
3. WHERE the user requests the Emergency_Footage view and no Event_Clips or locked clips exist, THE Media_Browser SHALL display a no-emergency-footage message.
4. WHEN the user locks a Normal_Clip, THE Settings_Controller SHALL request the Camera to protect the clip from automatic overwrite and, upon Camera confirmation within 10 seconds, update the clip indicator to protected within 3 seconds.
5. IF the Camera rejects the lock request or does not respond within 10 seconds, THEN THE Settings_Controller SHALL retain the clip's unprotected indicator and display a message indicating the lock failed.
6. WHEN the user unlocks a protected clip, THE Settings_Controller SHALL request the Camera to remove overwrite protection and, upon Camera confirmation within 10 seconds, update the clip indicator to unprotected within 3 seconds.
7. IF the Camera rejects the unlock request or does not respond within 10 seconds, THEN THE Settings_Controller SHALL retain the clip's protected indicator and display a message indicating the unlock failed.
8. WHEN the user downloads Emergency_Footage, THE Download_Manager SHALL store the clip in the Local_Library and mark the stored clip as protected.

### Requirement 7: Local Library Management

**User Story:** As a driver, I want to manage clips saved on my phone, so that I can review and free up space without a Camera connection.

#### Acceptance Criteria

1. WHILE the Connection_State is disconnected, THE App SHALL display the contents of the Local_Library.
2. WHEN the user opens the Local_Library, THE App SHALL display, for each stored clip, the recording start timestamp, the clip duration, and the clip file size, ordered by recording start timestamp in descending order.
3. IF the Local_Library contains no clips, THEN THE App SHALL display an empty-library message.
4. WHEN the user deletes a clip from the Local_Library, THE App SHALL remove the clip from device storage and update the Local_Library display.
5. IF deletion of a Local_Library clip fails, THEN THE App SHALL retain the clip in the Local_Library and display a deletion-failure message.
6. WHEN the user shares a clip from the Local_Library, THE App SHALL present the iOS share interface for the selected clip.
7. WHERE the user grants photo library permission, THE App SHALL provide a control to export a Local_Library clip to the iOS photo library.
8. IF the user requests export to the iOS photo library and photo library permission has not been granted, THEN THE App SHALL display a message directing the user to grant photo library permission.

### Requirement 8: Video Resolution Setting

**User Story:** As a driver, I want to adjust the Camera video resolution, so that I can balance video quality against storage usage.

#### Acceptance Criteria

1. WHEN the user opens the resolution setting AND the Connection_State is connected, THE Settings_Controller SHALL request the supported resolution options from the Camera within 2 seconds and display the returned list along with the currently selected resolution.
2. IF the Camera does not return the supported resolution options within 5 seconds of the request, THEN THE Settings_Controller SHALL disable the resolution control and display a retrieval-failure message indicating that the options could not be loaded.
3. WHEN the user selects a resolution option AND the Camera accepts the change within 5 seconds, THE Settings_Controller SHALL update the displayed current selection to the newly selected resolution and display a confirmation message.
4. IF the Camera rejects the resolution change OR does not respond within 5 seconds of the submission, THEN THE Settings_Controller SHALL retain the previously displayed selection and display a change-failure message indicating that the resolution was not changed.
5. IF the Connection_State is not connected when the user opens the resolution setting, THEN THE Settings_Controller SHALL disable the resolution control and display a connection-required message.
6. WHILE a resolution change submission is in progress, THE Settings_Controller SHALL disable the resolution control until a response is received or the 5 second timeout elapses.

### Requirement 9: Collision Sensitivity Setting

**User Story:** As a driver, I want to change the collision sensitivity, so that event recording matches my driving conditions.

#### Acceptance Criteria

1. WHILE the Connection_State is connected, WHEN the user opens the collision sensitivity setting, THE Settings_Controller SHALL retrieve and display the available Collision_Sensitivity levels and highlight the current level received from the Camera.
2. WHEN the user selects a Collision_Sensitivity level, THE Settings_Controller SHALL send the selected level to the Camera and display an in-progress indicator until a response is received or 10 seconds have elapsed.
3. WHEN the Camera accepts the Collision_Sensitivity change within 10 seconds, THE Settings_Controller SHALL update the displayed level to the newly accepted value and display a success notification for at least 3 seconds.
4. IF the Camera rejects the Collision_Sensitivity change or does not respond within 10 seconds, THEN THE Settings_Controller SHALL retain the previously displayed level and display an error notification indicating the change failed.
5. IF the Connection_State changes to disconnected while a Collision_Sensitivity change is pending, THEN THE Settings_Controller SHALL cancel the pending change, retain the previously displayed level, and display an error notification indicating the connection was lost.

### Requirement 10: Audio Recording Toggle

**User Story:** As a driver, I want to toggle audio recording, so that I control whether in-cabin audio is captured.

#### Acceptance Criteria

1. WHILE the Connection_State is connected, WHEN the user opens the audio recording setting, THE Settings_Controller SHALL retrieve the audio recording state from the Camera and display it as either enabled or disabled.
2. WHILE the Connection_State is connected, WHEN the user toggles audio recording, THE Settings_Controller SHALL send the requested audio recording state to the Camera.
3. WHEN the Camera accepts the audio recording state change within 10 seconds, THE Settings_Controller SHALL update the displayed audio recording state to match the accepted value.
4. IF the Camera rejects the audio recording state change, THEN THE Settings_Controller SHALL retain the previously displayed state and display a message indicating the change failed.
5. IF the Camera does not respond to the audio recording state change within 10 seconds, THEN THE Settings_Controller SHALL retain the previously displayed state and display a message indicating the change failed.
6. IF the user attempts to toggle audio recording while the Connection_State is not connected, THEN THE Settings_Controller SHALL not send the change and SHALL display a message indicating that a camera connection is required.

### Requirement 11: Parking Monitoring Mode Setting

**User Story:** As a driver, I want to set up parking monitoring modes, so that the Camera protects my vehicle while parked.

#### Acceptance Criteria

1. WHILE the Connection_State is connected, WHEN the user opens the parking monitoring setting, THE Settings_Controller SHALL retrieve the list of supported Parking_Monitoring_Mode options and the currently active mode from the Camera and display them.
2. WHILE the Connection_State is connected, WHEN the user selects a Parking_Monitoring_Mode, THE Settings_Controller SHALL send the selected mode to the Camera and, upon acceptance by the Camera within 10 seconds, display a success notification indicating the mode has been changed.
3. IF the Camera rejects the Parking_Monitoring_Mode change or does not respond within 10 seconds, THEN THE Settings_Controller SHALL retain the previously displayed mode and display an error notification indicating the mode change failed.
4. WHERE the selected Parking_Monitoring_Mode exposes a configurable sensitivity value, THE Settings_Controller SHALL retrieve the supported sensitivity range and current value from the Camera and display a control allowing the user to set sensitivity within that range.
5. WHERE the selected Parking_Monitoring_Mode exposes a configurable sensitivity value, WHEN the user adjusts the sensitivity value and confirms, THE Settings_Controller SHALL send the updated value to the Camera and, upon acceptance by the Camera within 10 seconds, display a success notification indicating the sensitivity has been updated.
6. IF the Camera rejects the sensitivity value change or does not respond within 10 seconds, THEN THE Settings_Controller SHALL revert the displayed sensitivity to the previous value and display an error notification indicating the sensitivity change failed.
7. IF the Connection_State is not connected when the user opens the parking monitoring setting, THEN THE Settings_Controller SHALL display a notification indicating that a Camera connection is required and SHALL NOT display the parking monitoring mode options.

### Requirement 12: Settings Synchronization and Error Handling

**User Story:** As a driver, I want the App to reflect the Camera's actual settings, so that I trust the values shown.

#### Acceptance Criteria

1. WHEN the Connection_State changes to connected, THE Settings_Controller SHALL display a loading indicator, retrieve the current Camera settings, and replace the loading indicator with the retrieved values.
2. IF a settings retrieval does not complete within 10 seconds or the Connection_State changes to disconnected during retrieval, THEN THE Settings_Controller SHALL display a settings-unavailable message and provide a retry control that permits a maximum of 3 consecutive retry attempts before requiring a new connection.
3. WHEN the Camera reports a settings value that differs from the displayed value, THE Settings_Controller SHALL update the display to the Camera-reported value within 2 seconds of receiving the report.
4. IF the Camera rejects or fails to apply a user-initiated setting change, THEN THE Settings_Controller SHALL revert the displayed value to the Camera's current value and display a message indicating the change was not applied.
