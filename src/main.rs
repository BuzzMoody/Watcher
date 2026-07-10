use chrono::Local;
use crossbeam_channel::unbounded;
use notify::{Config, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use notify::event::{AccessKind, AccessMode, ModifyKind, RenameMode};
use ssh2::{Session, OpenFlags, OpenType};
use std::collections::HashSet;
use std::env;
use std::fs;
use std::io::{Read, Write, Seek, SeekFrom};
use std::net::TcpStream;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};
use std::process;

fn current_time() -> String {
    let now = Local::now();
    let fmt = now.format("%d/%m/%y %I:%M %p").to_string();
    let chars = fmt.chars().collect::<Vec<char>>();
    let mut clean = String::new();
    let mut skip_next_if_zero = true;
    for i in 0..chars.len() {
        if skip_next_if_zero && chars[i] == '0' {
            skip_next_if_zero = false;
            continue;
        }
        if chars[i] == ' ' || chars[i] == '/' {
            skip_next_if_zero = true;
        } else {
            skip_next_if_zero = false;
        }
        clean.push(chars[i]);
    }
    clean
}

fn is_ignored_file(name: &str) -> bool {
    let lower = name.to_lowercase();
    if lower == "thumbs.db" || lower == "desktop.ini" || lower == ".ds_store" {
        return true;
    }
    if lower.starts_with("._") {
        return true;
    }
    false
}

struct TokenBucket {
    tokens: Mutex<f64>,
    last_update: Mutex<Instant>,
    rate_per_sec: f64,
    capacity: f64,
}

impl TokenBucket {
    fn new(rate_per_sec: f64, capacity: f64) -> Self {
        Self {
            tokens: Mutex::new(capacity),
            last_update: Mutex::new(Instant::now()),
            rate_per_sec,
            capacity,
        }
    }

    fn consume(&self, tokens: f64) {
        if self.rate_per_sec <= 0.0 {
            return;
        }
        loop {
            let mut current_tokens = self.tokens.lock().unwrap();
            let mut last_update = self.last_update.lock().unwrap();
            let now = Instant::now();
            let elapsed = now.duration_since(*last_update).as_secs_f64();
            
            *current_tokens += elapsed * self.rate_per_sec;
            if *current_tokens > self.capacity {
                *current_tokens = self.capacity;
            }
            *last_update = now;

            if *current_tokens >= tokens {
                *current_tokens -= tokens;
                return;
            } else {
                let deficit = tokens - *current_tokens;
                let wait_time = deficit / self.rate_per_sec;
                drop(current_tokens);
                drop(last_update);
                thread::sleep(Duration::from_secs_f64(wait_time));
            }
        }
    }
}

fn connect_ssh(remote_dest: &str, ssh_port: u16, ssh_key: &str) -> Result<Session, String> {
    let parts: Vec<&str> = remote_dest.split(':').collect();
    if parts.len() < 2 {
        return Err("Invalid REMOTE_DEST format, expected user@host:/path".into());
    }
    let user_host = parts[0];
    let user_host_parts: Vec<&str> = user_host.split('@').collect();
    if user_host_parts.len() != 2 {
         return Err("Invalid REMOTE_DEST format, expected user@host:/path".into());
    }
    let username = user_host_parts[0];
    let hostname = user_host_parts[1];

    let tcp = match TcpStream::connect((hostname, ssh_port)) {
        Ok(t) => t,
        Err(e) => return Err(format!("Failed to connect to {}:{} - {}", hostname, ssh_port, e)),
    };
    let _ = tcp.set_nodelay(true);

    let mut sess = match Session::new() {
        Ok(s) => s,
        Err(e) => return Err(format!("Failed to create SSH session - {}", e)),
    };
    sess.set_tcp_stream(tcp);
    sess.set_timeout(30000);
    if let Err(e) = sess.handshake() {
        return Err(format!("SSH handshake failed - {}", e));
    }

    if let Err(e) = sess.userauth_pubkey_file(username, None, Path::new(ssh_key), None) {
        return Err(format!("SSH auth failed - {}", e));
    }

    Ok(sess)
}

enum JobResult {
    Success(String),
    Failed(String),
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let remote_dest = env::var("REMOTE_DEST").expect("ERROR: REMOTE_DEST environment variable not set.");
    let ssh_port = env::var("SSH_PORT").unwrap_or_else(|_| "222".to_string()).parse::<u16>().unwrap_or(222);
    let ssh_key = env::var("SSH_KEY").unwrap_or_else(|_| "/root/.ssh/id_rsa".to_string());
    
    if args.iter().any(|a| a == "--health") {
        match connect_ssh(&remote_dest, ssh_port, &ssh_key) {
            Ok(_) => {
                println!("{} | 🟢 Health check passed: SSH connection successful.", current_time());
                process::exit(0);
            },
            Err(e) => {
                eprintln!("{} | ❌ ERROR: Health check failed. {}", current_time(), e);
                process::exit(1);
            }
        }
    }

    let source_dir = env::var("SOURCE_DIR").unwrap_or_else(|_| "/transfer".to_string());
    let bwlimit_kb = env::var("BWLIMIT_KB").unwrap_or_else(|_| "9375".to_string()).parse::<u64>().unwrap_or(9375);
    let bwlimit_mb = bwlimit_kb / 125;
    let sync_interval = env::var("SYNC_INTERVAL").unwrap_or_else(|_| "10".to_string()).parse::<u64>().unwrap_or(10);
    let max_concurrent = env::var("MAX_CONCURRENT_UPLOADS").unwrap_or_else(|_| "4".to_string()).parse::<usize>().unwrap_or(4);
    
    let parts: Vec<&str> = remote_dest.split(':').collect();
    let remote_path = parts[1].to_string();

    println!("Monitoring:          📤 {}", source_dir);
    println!("Destination:         📥 {}", remote_dest);
    println!("Bandwidth limit:     🌐 {} KB/s ({} Mbit/s)", bwlimit_kb, bwlimit_mb);
    println!("Sync interval:       ⏰ {}s", sync_interval);
    println!("Concurrency:         ⚡ {} streams", max_concurrent);
    println!("-");
    println!("{} | 🟢 Starting transfer watcher...", current_time());

    println!("{} | 🔑 Checking SSH connectivity...", current_time());
    match connect_ssh(&remote_dest, ssh_port, &ssh_key) {
        Ok(_) => {
            println!("{} | 🔓 Remote connection OK.", current_time());
        },
        Err(e) => {
            println!("{} | 🔐 WARNING: SSH connectivity test failed. ({})", current_time(), e);
            println!("{} | ❗ NOTE: This may not indicate a real failure — SFTP may still succeed later.", current_time());
        }
    }
    println!("-");

    let events = Arc::new(Mutex::new(HashSet::new()));

    println!("{} | 🔎 Checking for unsynced files...", current_time());
    let mut added = 0;
    for entry in walkdir::WalkDir::new(&source_dir).into_iter().filter_map(|e| e.ok()) {
        if entry.file_type().is_file() {
            if let Ok(rel_path) = entry.path().strip_prefix(&source_dir) {
                if let Some(file_name) = rel_path.file_name().and_then(|n| n.to_str()) {
                    if is_ignored_file(file_name) {
                        let _ = fs::remove_file(entry.path());
                        continue;
                    }
                }
                events.lock().unwrap().insert(rel_path.to_string_lossy().to_string());
                println!("{} | ➕ Added unsynced file: {}", current_time(), rel_path.display());
                added += 1;
            }
        }
    }
    if added == 0 {
        println!("{} | 📂 No unsynced files found.", current_time());
    } else {
        println!("{} | 📦 Found {} unsynced file(s).", current_time(), added);
    }
    println!("-");

    let events_clone = Arc::clone(&events);
    let source_dir_clone = source_dir.clone();
    
    thread::spawn(move || {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut watcher = RecommendedWatcher::new(tx, Config::default()).unwrap();
        watcher.watch(Path::new(&source_dir_clone), RecursiveMode::Recursive).unwrap();

        for res in rx {
            match res {
                Ok(event) => {
                    let is_write = match event.kind {
                        EventKind::Access(AccessKind::Close(AccessMode::Write)) => true,
                        EventKind::Modify(ModifyKind::Name(RenameMode::To)) => true,
                        EventKind::Modify(ModifyKind::Name(RenameMode::Both)) => true,
                        _ => false,
                    };
                    if is_write {
                        for path in event.paths {
                            if path.is_file() {
                                if let Ok(rel_path) = path.strip_prefix(&source_dir_clone) {
                                    if let Some(file_name) = rel_path.file_name().and_then(|n| n.to_str()) {
                                        if is_ignored_file(file_name) {
                                            let _ = fs::remove_file(&path);
                                            continue;
                                        }
                                    }
                                    events_clone.lock().unwrap().insert(rel_path.to_string_lossy().to_string());
                                }
                            }
                        }
                    }
                },
                Err(e) => println!("{} | ❌ ERROR: Watch error: {:?}", current_time(), e),
            }
        }
    });

    let bwlimit_bytes_per_sec = (bwlimit_kb * 1024) as f64;
    let chunk_size = 1024 * 1024;
    let capacity = if bwlimit_bytes_per_sec > 0.0 {
        bwlimit_bytes_per_sec.max(chunk_size as f64 * max_concurrent as f64)
    } else {
        0.0
    };
    let bucket = Arc::new(TokenBucket::new(bwlimit_bytes_per_sec, capacity));

    let (task_tx, task_rx) = unbounded::<String>();
    let (result_tx, result_rx) = unbounded::<JobResult>();

    for _ in 0..max_concurrent {
        let rx = task_rx.clone();
        let tx = result_tx.clone();
        let bucket = bucket.clone();
        let remote_dest = remote_dest.clone();
        let ssh_port = ssh_port;
        let ssh_key = ssh_key.clone();
        let source_dir = source_dir.clone();
        let remote_path = remote_path.clone();

        thread::spawn(move || {
            let mut sess_opt: Option<Session> = None;

            for mut rel_path in rx {
                let mut local_path = Path::new(&source_dir).join(&rel_path);
                if !local_path.exists() {
                    let _ = tx.send(JobResult::Success(rel_path));
                    continue;
                }

                if sess_opt.is_none() {
                    sess_opt = connect_ssh(&remote_dest, ssh_port, &ssh_key).ok();
                }

                let mut success = false;
                if let Some(sess) = &sess_opt {
                    if let Ok(sftp) = sess.sftp() {
                        let dest_path = Path::new(&remote_path).join(&rel_path);
                        let mut final_dest = dest_path.clone();

                        if let Some(parent) = final_dest.parent() {
                            let _ = sess.channel_session().and_then(|mut ch| {
                                ch.exec(&format!("mkdir -p \"{}\"", parent.display())).unwrap();
                                Ok(())
                            });
                        }

                        let mut duplicate_found = false;
                        if let Ok(stat) = sftp.stat(&final_dest) {
                            if let Ok(local_meta) = fs::metadata(&local_path) {
                                if stat.size.unwrap_or(0) == local_meta.len() {
                                    println!("{} | ⚠️ DUPLICATE: Remote file {} already exists with the same size. Skipping transfer and deleting local copy.", current_time(), final_dest.display());
                                    let _ = fs::remove_file(&local_path);
                                    duplicate_found = true;
                                    success = true;
                                }
                            }

                            if !duplicate_found {
                                let now = Local::now().format("%Y%m%d_%H%M%S");
                                let ext = final_dest.extension().and_then(|e| e.to_str()).unwrap_or("");
                                let stem = final_dest.file_stem().and_then(|s| s.to_str()).unwrap_or("file");
                                let new_name = if ext.is_empty() {
                                    format!("{}_{}", stem, now)
                                } else {
                                    format!("{}_{}.{}", stem, now, ext)
                                };
                                final_dest = final_dest.with_file_name(&new_name);
                                
                                let new_local_path = local_path.with_file_name(&new_name);
                                if fs::rename(&local_path, &new_local_path).is_ok() {
                                    local_path = new_local_path;
                                    rel_path = Path::new(&rel_path).with_file_name(&new_name).to_string_lossy().to_string();
                                    println!("{} | 🔄 COLLISION: Renamed local file to {} to allow for partial resume.", current_time(), new_name);
                                }
                            }
                        }

                        if !duplicate_found {
                            let mut temp_dest = final_dest.clone();
                            let temp_name = format!("{}.transferring", final_dest.file_name().unwrap().to_string_lossy());
                            temp_dest.set_file_name(temp_name);

                            let mut start_pos = 0;
                            if let Ok(stat) = sftp.stat(&temp_dest) {
                                start_pos = stat.size.unwrap_or(0);
                            }

                            if let Ok(mut local_f) = fs::File::open(&local_path) {
                                if start_pos > 0 {
                                    if let Ok(local_meta) = local_f.metadata() {
                                        if start_pos <= local_meta.len() {
                                            println!("{} | ⏪ RESUMING: {} from byte {}", current_time(), rel_path, start_pos);
                                            let _ = local_f.seek(SeekFrom::Start(start_pos));
                                        } else {
                                            start_pos = 0;
                                        }
                                    }
                                }

                                let remote_f_res = if start_pos > 0 {
                                    sftp.open_mode(&temp_dest, OpenFlags::WRITE | OpenFlags::APPEND, 0o644, OpenType::File)
                                } else {
                                    sftp.create(&temp_dest)
                                };

                                if let Ok(mut remote_f) = remote_f_res {
                                    let mut buffer = vec![0; chunk_size];
                                    let mut transfer_ok = true;

                                    loop {
                                        let n = match local_f.read(&mut buffer) {
                                            Ok(0) => break,
                                            Ok(n) => n,
                                            Err(_) => {
                                                transfer_ok = false;
                                                break;
                                            }
                                        };

                                        bucket.consume(n as f64);

                                        if remote_f.write_all(&buffer[..n]).is_err() {
                                            transfer_ok = false;
                                            break;
                                        }
                                    }

                                    if transfer_ok {
                                        // sftp.rename flags: Some(RenameFlags::OVERWRITE | RenameFlags::ATOMIC)
                                        // Some ssh2 versions don't take Option, let's use None for safety
                                        let _ = sftp.rename(&temp_dest, &final_dest, None);
                                        let _ = fs::remove_file(&local_path);
                                        success = true;
                                    }
                                }
                            }
                        }
                    } else {
                        sess_opt = None; // Force reconnect
                    }
                }

                if success {
                    let _ = tx.send(JobResult::Success(rel_path));
                } else {
                    let _ = tx.send(JobResult::Failed(rel_path));
                }
            }
        });
    }

    loop {
        thread::sleep(Duration::from_secs(sync_interval));
        let mut current_events = HashSet::new();
        {
            let mut guard = events.lock().unwrap();
            if guard.is_empty() {
                continue;
            }
            std::mem::swap(&mut *guard, &mut current_events);
        }

        let total_files = current_events.len();
        println!("{} | 🔍 Detected file changes. Starting batch transfer of {} files...", current_time(), total_files);

        for rel_path in &current_events {
            task_tx.send(rel_path.clone()).unwrap();
        }

        let mut success_count = 0;
        let mut failed_events = HashSet::new();

        for _ in 0..total_files {
            match result_rx.recv() {
                Ok(JobResult::Success(_)) => {
                    success_count += 1;
                },
                Ok(JobResult::Failed(rel_path)) => {
                    failed_events.insert(rel_path);
                },
                Err(_) => break,
            }
        }

        if failed_events.is_empty() {
            println!("{} | ✔️ SUCCESS: Batch transfer complete. Transferred {} files.", current_time(), success_count);
        } else {
            println!("{} | ❌ ERROR: Batch transfer had {} failures. Files remain in event list.", current_time(), failed_events.len());
            events.lock().unwrap().extend(failed_events);
        }
        println!("-");
    }
}
