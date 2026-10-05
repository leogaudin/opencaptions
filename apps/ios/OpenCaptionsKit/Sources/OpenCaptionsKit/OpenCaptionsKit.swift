import OpenCaptionsEngine

/// The caption engine's C ABI has 17 exports; touching one proves the binary links.
public enum OpenCaptionsKit {
    /// Bytes left in the engine's result buffer by the last call.
    public static var engineResultLength: Int { oc_result_len() }
}
