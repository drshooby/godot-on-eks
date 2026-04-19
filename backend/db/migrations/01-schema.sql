-- Phase 2 shared schema (MySQL 8). Loaded by Compose MySQL init only on first volume create.

CREATE TABLE IF NOT EXISTS players (
    id CHAR(36) NOT NULL PRIMARY KEY,
    email VARCHAR(255) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
);

CREATE TABLE IF NOT EXISTS scores (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    player_id CHAR(36) NOT NULL,
    score INT NOT NULL,
    wave_reached INT NOT NULL,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    CONSTRAINT fk_scores_player FOREIGN KEY (player_id) REFERENCES players (id)
);

CREATE INDEX idx_scores_player ON scores (player_id);
CREATE INDEX idx_scores_score_desc ON scores (score DESC);

CREATE TABLE IF NOT EXISTS game_sessions (
    id CHAR(36) NOT NULL PRIMARY KEY,
    player_id CHAR(36) NULL,
    started_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    ended_at DATETIME(6) NULL,
    score INT NULL,
    waves INT NULL,
    kills INT NULL,
    CONSTRAINT fk_sessions_player FOREIGN KEY (player_id) REFERENCES players (id)
);

CREATE INDEX idx_sessions_player_started ON game_sessions (player_id, started_at DESC);
