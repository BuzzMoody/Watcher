use chrono::Local;
use notify::{Config, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use notify::event::{AccessKind, AccessMode, ModifyKind, RenameMode};
use ssh2::Session;
use std::collections::HashSet;
use std::env;
use std::fs;
use std::io::{Read, Write};
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
    tcp.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    tcp.set_write_timeout(Some(Duration::from_secs(5))).unwrap();

    let mut sess = match Session::new() {
        Ok(s) => s,
        Err(e) => return Err(format!("Failed to create SSH session - {}", e)),
    };
    sess.set_tcp_stream(tcp);
    if let Err(e) = sess.handshake() {
        return Err(format!("SSH handshake failed - {}", e));
    }

    if let Err(e) = sess.userauth_pubkey_file(username, None, Path::new(ssh_key), None) {
        return Err(format!("SSH auth failed - {}", e));
    }

    Ok(sess)
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
    
    let parts: Vec<&str> = remote_dest.split(':').collect();
    let remote_path = parts[1].to_string();

    println!("Monitoring:          📤 {}", source_dir);
    println!("Destination:         📥 {}", remote_dest);
    println!("Bandwidth limit:     🌐 {} KB/s ({} Mbit/s)", bwlimit_kb, bwlimit_mb);
    println!("Sync interval:       ⏰ {}s", sync_interval);
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

        println!("{} | 🔍 Detected file changes. Starting batch transfer...", current_time());

        match connect_ssh(&remote_dest, ssh_port, &ssh_key) {
            Ok(sess) => {
                let sftp = match sess.sftp() {
                    Ok(s) => s,
                    Err(_) => {
                        println!("{} | ❌ ERROR: Failed to init SFTP.", current_time());
                        events.lock().unwrap().extend(current_events);
                        println!("-");
                        continue;
                    }
                };

                let mut success_count = 0;
                let mut failed_events = HashSet::new();
                let bwlimit_bytes = bwlimit_kb * 1024;
                let chunk_size = 32 * 1024;

                for rel_path in current_events {
                    let local_path = Path::new(&source_dir).join(&rel_path);
                    if !local_path.exists() {
                        continue;
                    }

                    let dest_path = Path::new(&remote_path).join(&rel_path);
                    let mut final_dest = dest_path.clone();

                    if let Some(parent) = final_dest.parent() {
                        let _ = sess.channel_session().and_then(|mut ch| {
                            ch.exec(&format!("mkdir -p \"{}\"", parent.display())).unwrap();
                            Ok(())
                        });
                    }

                    if let Ok(stat) = sftp.stat(&final_dest) {
                        if let Ok(local_meta) = fs::metadata(&local_path) {
                            if stat.size.unwrap_or(0) == local_meta.len() {
                                println!("{} | ⚠️ DUPLICATE: Remote file {} already exists with the same size. Skipping transfer and deleting local copy.", current_time(), final_dest.display());
                                let _ = fs::remove_file(&local_path);
                                success_count += 1;
                                continue;
                            }
                        }

                        let now = Local::now().format("%Y%m%d_%H%M%S");
                        let ext = final_dest.extension().and_then(|e| e.to_str()).unwrap_or("");
                        let stem = final_dest.file_stem().and_then(|s| s.to_str()).unwrap_or("file");
                        let new_name = if ext.is_empty() {
                            format!("{}_{}", stem, now)
                        } else {
                            format!("{}_{}.{}", stem, now, ext)
                        };
                        final_dest = final_dest.with_file_name(new_name);
                    }

                    let mut local_f = match fs::File::open(&local_path) {
                        Ok(f) => f,
                        Err(_) => {
                            failed_events.insert(rel_path);
                            continue;
                        }
                    };

                    let mut remote_f = match sftp.create(&final_dest) {
                        Ok(f) => f,
                        Err(_) => {
                            failed_events.insert(rel_path);
                            continue;
                        }
                    };

                    let mut buffer = vec![0; chunk_size];
                    let mut bytes_sent_in_second = 0;
                    let mut second_start = Instant::now();
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

                        if remote_f.write_all(&buffer[..n]).is_err() {
                            transfer_ok = false;
                            break;
                        }

                        if bwlimit_bytes > 0 {
                            bytes_sent_in_second += n as u64;
                            if bytes_sent_in_second >= bwlimit_bytes {
                                let elapsed = second_start.elapsed();
                                if elapsed < Duration::from_secs(1) {
                                    thread::sleep(Duration::from_secs(1) - elapsed);
                                }
                                second_start = Instant::now();
                                bytes_sent_in_second = 0;
                            }
                        }
                    }

                    if transfer_ok {
                        let _ = fs::remove_file(&local_path);
                        success_count += 1;
                    } else {
                        failed_events.insert(rel_path);
                    }
                }

                if failed_events.is_empty() {
                    println!("{} | ✔️ SUCCESS: Batch transfer complete. Transferred {} files.", current_time(), success_count);
                } else {
                    println!("{} | ❌ ERROR: Batch transfer had {} failures. Files remain in event list.", current_time(), failed_events.len());
                    events.lock().unwrap().extend(failed_events);
                }
                println!("-");
            },
            Err(e) => {
                println!("{} | ❌ ERROR: Batch transfer failed. ({})", current_time(), e);
                events.lock().unwrap().extend(current_events);
                println!("-");
            }
        }
    }
}
