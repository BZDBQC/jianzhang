CREATE TABLE `ledger_chunks` (
	`user_id` text NOT NULL,
	`chunk_index` integer NOT NULL,
	`payload` text NOT NULL,
	PRIMARY KEY(`user_id`, `chunk_index`)
);
--> statement-breakpoint
CREATE TABLE `ledgers` (
	`user_id` text PRIMARY KEY NOT NULL,
	`payload` text NOT NULL,
	`revision` integer DEFAULT 0 NOT NULL,
	`updated_at` text NOT NULL,
	`write_token` text DEFAULT '' NOT NULL
);
