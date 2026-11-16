fn main() {
    let t = std::thread::spawn(|| std::env::args().collect::<Vec<_>>());
    println!("Hello from linux-none: {:?}", t.join().unwrap());
}
