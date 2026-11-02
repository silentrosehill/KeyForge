import Foundation

@main
struct UpdateVersionTests {
    static func main() {
        precondition(UpdateVersion.isNewer("v1.12.0", than: "1.11.9"))
        precondition(UpdateVersion.isNewer("1.10.0", than: "1.9.99"))
        precondition(!UpdateVersion.isNewer("v1.12.0", than: "1.12"))
        precondition(!UpdateVersion.isNewer("1.10.2", than: "1.12.0"))
        precondition(UpdateVersion.isNewer("2", than: "1.99.99"))
        for bad in ["", "v", "1..2", "1.2-beta", "https://bad", "1.2.3.4.5", "-1", "١.٢"] {
            precondition(UpdateVersion.numbers(bad) == nil)
        }
        print("Update version tests passed: numeric ordering, equivalent versions, no downgrades, malformed tags")
    }
}
