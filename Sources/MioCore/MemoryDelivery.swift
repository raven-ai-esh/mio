import Foundation

extension MioStore {
    /// Called by the local native server after observing its original response write.
    /// This authority is never exposed through execute or an MCP tool.
    public func observeMemoryDelivery(metadata: JSONValue, context: AccessContext, peerPID: Int32, state: String, errorCode: String? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard ["socket_written","frame_too_large","socket_write_failed"].contains(state), case .agent(let token)=context, !token.isEmpty else { throw MioError("forbidden","Invalid native delivery observation") }
        let digest=hash(Data(token.utf8))
        guard let profile=try all("profile").first(where:{$0["token_hash"].stringValue == digest}) else { throw MioError("unauthorized","Unknown delivery identity") }
        try db.transaction { try recordMemoryDelivery(metadata:metadata,actor:profile["id"].stringValue!,peerPID:peerPID,state:state,origin:"server_observed",errorCode:errorCode,scope:nil) }
    }
    func recordMemoryDelivery(metadata: JSONValue, actor: String, peerPID: Int32, state: String, origin: String, errorCode: String?, scope: Scope?) throws {
        guard let transport=metadata["transport_session_id"].stringValue, let requestID=metadata["request_id"].stringValue, !transport.isEmpty, !requestID.isEmpty, peerPID>0 else { throw MioError("invalid_params","Delivery must identify an actual adapter request") }
        let sid="session-"+hash(Data((actor+"\u{0}"+String(transport.prefix(128))).utf8))
        let cid="call-"+hash(Data((actor+"\u{0}"+sid+"\u{0}"+String(requestID.prefix(128))).utf8))
        guard let session=try entity("session",sid), !session["deleted"].boolValue, session["source"].stringValue == Self.interactionSource,
              session["actor"].stringValue == actor, let call=try entity("interaction",cid), call["actor"].stringValue == actor,
              call["session_id"].stringValue == sid, call["adapter_pid"].intValue == Int(peerPID), session["adapter_pid"].intValue == Int(peerPID) else { throw MioError("forbidden","Delivery observation does not own this request") }
        guard let endID=call["end_event_id"].stringValue else { throw MioError("interaction_active","Execution has not finished") }
        if let scope { try requireVisibility(call,scope); try requireSpace(call["space_id"].stringValue ?? "",scope) }
        let sourceID=cid+":delivery:"+origin+":"+state
        let eid="event-"+hash(Data((sid+"\u{0}initial\u{0}"+sourceID).utf8))
        if try entity("event",eid) != nil { return }
        let observed=now()
        var data: [String:JSONValue] = ["id":.string(eid),"source_id":.string(sourceID),"session_id":.string(sid),"space_id":call["space_id"],"kind":.string("memory_operation"),"role":.string("agent"),"tool_name":call["method"],"method":call["method"],"text":.string("Memory operation \(call["method"].stringValue ?? "operation"). Delivery \(state). Observation \(origin). Execution outcome \(call["outcome"].stringValue ?? "unknown"). Client consumption not observed."),"timestamp":.string(observed),"observed_at":.string(observed),"phase":.string("delivery"),"interaction_id":.string(cid),"actor":.string(actor),"generation":.string("initial"),"source_sequence":.number(Double(session["event_count"].intValue)),"required_space_ids":call["required_space_ids"],"target_space_ids":call["target_space_ids"],"started_at":call["started_at"],"finished_at":.null,"duration_ms":.null,"outcome":call["outcome"],"delivery_state":.string(state),"observation_type":.string(origin),"consumption_observed":.bool(false),"request":.object([:]),"result_refs":.array([]),"execution_end_event_id":.string(endID),"receipt":call["receipt"],"operation_id":call["operation_id"],"request_fingerprint":call["request_fingerprint"],"owner_pid":call["owner_pid"],"owner_device_id":call["owner_device_id"],"adapter_pid":call["adapter_pid"],"replayed":call["replayed"]]
        if let errorCode { data["error_code"] = .string(["frame_too_large","socket_write_failed","stdout_write_failed"].contains(errorCode) ? errorCode : "delivery_failed") }
        _=try record("event",entityID:eid,data:.object(data))
    }
}
