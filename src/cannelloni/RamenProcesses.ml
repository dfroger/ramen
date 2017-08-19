open Batteries
open Log
module C = RamenConf
module N = RamenConf.Node
module SL = RamenSharedTypes.Layer

let run_background cmd args env =
  let open Unix in
  (* prog name should be first arg *)
  let prog_name = Filename.basename cmd in
  let args = Array.init (Array.length args + 1) (fun i ->
      if i = 0 then prog_name else args.(i-1))
  in
  !logger.info "Running %s with args %a and env %a"
    cmd
    (Array.print String.print) args
    (Array.print String.print) env ;
  match fork () with
  | 0 -> execve cmd args env
  | pid -> pid
    (* TODO: A monitoring thread that report the error in the node structure *)

let run conf layer =
  let open C.Layer in
  match layer.persist.status with
  | SL.Edition ->
    raise (C.InvalidCommand "Cannot run if not compiled")
  | SL.Running ->
    raise (C.InvalidCommand "Graph is already running")
  | SL.Compiling ->
    raise (C.InvalidCommand "Graph is being compiled already")
  | SL.Compiled ->
    (* First prepare all the required ringbuffers *)
    let rb_name_of node = RingBufLib.in_ringbuf_name node.N.signature
    and rb_name_for_export_of node = RingBufLib.exp_ringbuf_name node.N.signature
    and rb_sz_words = 1000000 in
    !logger.info "Creating ringbuffers..." ;
    Hashtbl.iter (fun _ node ->
        RingBuf.create (rb_name_of node) rb_sz_words ;
        if Lang.Operation.is_exporting node.N.operation then
          RingBuf.create (rb_name_for_export_of node) rb_sz_words
      ) layer.persist.nodes ;
    (* Now run everything *)
    !logger.info "Launching generated programs..." ;
    let now = Unix.gettimeofday () in
    Hashtbl.iter (fun _ node ->
        let command = Option.get node.N.command
        and output_ringbufs = List.map rb_name_of node.N.children in
        let output_ringbufs =
          if Lang.Operation.is_exporting node.N.operation then
            rb_name_for_export_of node :: output_ringbufs
          else output_ringbufs in
        let out_ringbuf_ref = RingBufLib.out_ringbuf_names_ref node.N.signature in
        File.write_lines out_ringbuf_ref (List.enum output_ringbufs) ;
        let env = [|
          "debug="^ string_of_bool conf.C.debug ;
          "input_ringbuf="^ rb_name_of node ;
          "output_ringbufs_ref="^ out_ringbuf_ref ;
          "report_url="^ conf.C.ramen_url
                       ^ "/report/"^ Uri.pct_encode node.N.layer
                       ^ "/"^ Uri.pct_encode node.N.name |] in
        node.N.pid <- Some (run_background command [||] env)
      ) layer.persist.nodes ;
    C.Layer.set_status layer SL.Running ;
    layer.C.Layer.persist.C.Layer.last_started <- Some now ;
    layer.C.Layer.importing_threads <- Hashtbl.fold (fun _ node lst ->
        if Lang.Operation.is_exporting node.N.operation then (
          let rb = rb_name_for_export_of node in
          let tuple_type = C.tup_typ_of_temp_tup_type node.N.out_type in
          RamenExport.import_tuples rb node.N.name tuple_type :: lst
        ) else lst
      ) layer.C.Layer.persist.C.Layer.nodes [] ;
    C.save_graph conf

let string_of_process_status = function
  | Unix.WEXITED code -> Printf.sprintf "terminated with code %d" code
  | Unix.WSIGNALED sign -> Printf.sprintf "killed by signal %d" sign
  | Unix.WSTOPPED sign -> Printf.sprintf "stopped by signal %d" sign

let stop conf layer =
  match layer.C.Layer.persist.C.Layer.status with
  | SL.Edition | SL.Compiled ->
    raise (C.InvalidCommand "Graph is not running")
  | SL.Compiling ->
    (* FIXME: do as for Running and make sure run() check the status hasn't
     * changed before launching workers. *)
    raise (C.InvalidCommand "Graph is being compiled by another thread")
  | SL.Running ->
    !logger.info "Stopping layer..." ;
    let now = Unix.gettimeofday () in
    Hashtbl.iter (fun _ node ->
        !logger.debug "Stopping node %s" node.N.name ;
        match node.N.pid with
        | None ->
          !logger.error "Node %s has no pid?!" node.N.name
        | Some pid ->
          let open Unix in
          (try kill pid Sys.sigterm
          with Unix_error _ -> ()) ;
          (try
            let _, status = restart_on_EINTR (waitpid []) pid in
            !logger.info "Node %s %s"
              node.N.name (string_of_process_status status) ;
           with exn ->
            !logger.error "Cannot wait for pid %d: %s"
              pid (Printexc.to_string exn)) ;
          node.N.pid <- None
      ) layer.C.Layer.persist.C.Layer.nodes ;
    C.Layer.set_status layer SL.Compiled ;
    layer.C.Layer.persist.C.Layer.last_stopped <- Some now ;
    List.iter Lwt.cancel layer.C.Layer.importing_threads ;
    layer.C.Layer.importing_threads <- [] ;
    C.save_graph conf