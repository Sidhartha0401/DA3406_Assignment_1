-- Apply only AFTER recording the baseline. SQLite 3.44+.
-- F1: timestamp range and MAX first, video join payload second (covering).
CREATE INDEX IF NOT EXISTS a2_impression_time_video
    ON Impression(impressed_at, video_id);
-- F12: selective completed=1 equality first, impression join key second.
-- Covering for all ViewSegment columns read by F12.
CREATE INDEX IF NOT EXISTS a2_segment_completed_impression
    ON ViewSegment(completed, impression_id);
-- F11: parent root/recursive equality first; turn join second. Both keys are
-- bound in root setup, while parent-only recursive probes retain the prefix.
CREATE INDEX IF NOT EXISTS a2_toolcall_parent_turn
    ON ToolCall(parent_call_id, turn_id);
