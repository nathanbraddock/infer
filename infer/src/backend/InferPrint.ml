(*
 * Copyright (c) 2009 - 2013 Monoidics ltd.
 * Copyright (c) 2013 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)
open! IStd
module CLOpt = CommandLineOption
module Hashtbl = Caml.Hashtbl
module L = Logging
module F = Format

let print_usage_exit err_s =
  L.user_error "Load Error: %s@\n@." err_s ;
  Config.print_usage_exit ()


(** return the list of the .specs files in the results dir and libs, if they're defined *)
let load_specfiles () =
  let specs_files_in_dir dir =
    let is_specs_file fname =
      Sys.is_directory fname <> `Yes && Filename.check_suffix fname Config.specs_files_suffix
    in
    let all_filenames = try Array.to_list (Sys.readdir dir) with Sys_error _ -> [] in
    let all_filepaths = List.map ~f:(fun fname -> Filename.concat dir fname) all_filenames in
    List.filter ~f:is_specs_file all_filepaths
  in
  let result_specs_dir = DB.filename_to_string DB.Results_dir.specs_dir in
  specs_files_in_dir result_specs_dir


let error_desc_to_csv_string error_desc =
  let pp fmt = F.fprintf fmt "%a" Localise.pp_error_desc error_desc in
  Escape.escape_csv (F.asprintf "%t" pp)


let error_advice_to_csv_string error_desc =
  let pp fmt = F.fprintf fmt "%a" Localise.pp_error_advice error_desc in
  Escape.escape_csv (F.asprintf "%t" pp)


let error_desc_to_plain_string error_desc =
  let pp fmt = F.fprintf fmt "%a" Localise.pp_error_desc error_desc in
  let s = F.asprintf "%t" pp in
  let s = String.strip s in
  let s =
    (* end error description with a dot *)
    if String.is_suffix ~suffix:"." s then s else s ^ "."
  in
  s


let error_desc_to_dotty_string error_desc = Localise.error_desc_get_dotty error_desc

let error_desc_to_xml_tags error_desc =
  let tags = Localise.error_desc_get_tags error_desc in
  let subtree label contents = Io_infer.Xml.create_tree label [] [Io_infer.Xml.String contents] in
  List.map ~f:(fun (tag, value) -> subtree tag (Escape.escape_xml value)) tags


let get_bug_hash (kind: string) (type_str: string) (procedure_id: string) (filename: string)
    (node_key: Digest.t) (error_desc: Localise.error_desc) =
  let qualifier_tag_call_procedure = Localise.error_desc_get_tag_call_procedure error_desc in
  let qualifier_tag_value = Localise.error_desc_get_tag_value error_desc in
  Utils.better_hash
    ( kind
    , type_str
    , procedure_id
    , filename
    , node_key
    , qualifier_tag_call_procedure
    , qualifier_tag_value )


let exception_value = "exception"

let loc_trace_to_jsonbug_record trace_list ekind =
  match ekind with
  | Exceptions.Kinfo ->
      []
  | _ ->
      let tag_value_records_of_node_tag nt =
        match nt with
        | Errlog.Condition cond ->
            [ {Jsonbug_j.tag= Io_infer.Xml.tag_kind; value= "condition"}
            ; {Jsonbug_j.tag= Io_infer.Xml.tag_branch; value= Printf.sprintf "%B" cond} ]
        | Errlog.Exception exn_name ->
            let res = [{Jsonbug_j.tag= Io_infer.Xml.tag_kind; value= exception_value}] in
            let exn_str = Typ.Name.name exn_name in
            if String.is_empty exn_str then res
            else {Jsonbug_j.tag= Io_infer.Xml.tag_name; value= exn_str} :: res
        | Errlog.Procedure_start pname ->
            [ {Jsonbug_j.tag= Io_infer.Xml.tag_kind; value= "procedure_start"}
            ; {Jsonbug_j.tag= Io_infer.Xml.tag_name; value= Typ.Procname.to_string pname}
            ; {Jsonbug_j.tag= Io_infer.Xml.tag_name_id; value= Typ.Procname.to_filename pname} ]
        | Errlog.Procedure_end pname ->
            [ {Jsonbug_j.tag= Io_infer.Xml.tag_kind; value= "procedure_end"}
            ; {Jsonbug_j.tag= Io_infer.Xml.tag_name; value= Typ.Procname.to_string pname}
            ; {Jsonbug_j.tag= Io_infer.Xml.tag_name_id; value= Typ.Procname.to_filename pname} ]
      in
      let trace_item_to_record trace_item =
        { Jsonbug_j.level= trace_item.Errlog.lt_level
        ; filename= SourceFile.to_string trace_item.Errlog.lt_loc.Location.file
        ; line_number= trace_item.Errlog.lt_loc.Location.line
        ; column_number= trace_item.Errlog.lt_loc.Location.col
        ; description= trace_item.Errlog.lt_description
        ; node_tags=
            List.concat_map ~f:tag_value_records_of_node_tag trace_item.Errlog.lt_node_tags }
      in
      let record_list = List.rev (List.rev_map ~f:trace_item_to_record trace_list) in
      record_list


type summary_val =
  { vname: string
  ; vname_id: string
  ; vspecs: int
  ; vto: string
  ; vsymop: int
  ; verr: int
  ; vfile: string
  ; vflags: ProcAttributes.proc_flags
  ; vline: int
  ; vsignature: string
  ; vproof_trace: string }

(** compute values from summary data to export to csv format *)
let summary_values summary =
  let stats = summary.Specs.stats in
  let attributes = Specs.get_attributes summary in
  let err_log = Specs.get_err_log summary in
  let proc_name = Specs.get_proc_name summary in
  let signature = Specs.get_signature summary in
  let specs = Specs.get_specs_from_payload summary in
  let lines_visited =
    let visited = ref Specs.Visitedset.empty in
    let do_spec spec = visited := Specs.Visitedset.union spec.Specs.visited !visited in
    List.iter ~f:do_spec specs ;
    let visited_lines = ref Int.Set.empty in
    Specs.Visitedset.iter
      (fun (_, ls) -> List.iter ~f:(fun l -> visited_lines := Int.Set.add !visited_lines l) ls)
      !visited ;
    Int.Set.elements !visited_lines
  in
  let proof_trace =
    let pp_line fmt l = F.fprintf fmt "%d" l in
    let pp fmt = F.fprintf fmt "%a" (Pp.seq pp_line) lines_visited in
    F.asprintf "%t" pp
  in
  let pp_failure failure = F.asprintf "%a" SymOp.pp_failure_kind failure in
  { vname= Typ.Procname.to_string proc_name
  ; vname_id= Typ.Procname.to_filename proc_name
  ; vspecs= List.length specs
  ; vto= Option.value_map ~f:pp_failure ~default:"NONE" stats.Specs.stats_failure
  ; vsymop= stats.Specs.symops
  ; verr=
      Errlog.size
        (fun ekind in_footprint ->
          Exceptions.equal_err_kind ekind Exceptions.Kerror && in_footprint)
        err_log
  ; vflags= attributes.ProcAttributes.proc_flags
  ; vfile= SourceFile.to_string attributes.ProcAttributes.loc.Location.file
  ; vline= attributes.ProcAttributes.loc.Location.line
  ; vsignature= signature
  ; vproof_trace= proof_trace }


module ProcsCsv = struct
  (** Print the header of the procedures csv file, with column names *)
  let pp_header fmt () =
    Format.fprintf fmt "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s@\n"
      Io_infer.Xml.tag_name Io_infer.Xml.tag_name_id Io_infer.Xml.tag_specs Io_infer.Xml.tag_time
      Io_infer.Xml.tag_to Io_infer.Xml.tag_symop Io_infer.Xml.tag_err Io_infer.Xml.tag_file
      Io_infer.Xml.tag_line Io_infer.Xml.tag_loc Io_infer.Xml.tag_top Io_infer.Xml.tag_signature
      Io_infer.Xml.tag_weight Io_infer.Xml.tag_proof_coverage Io_infer.Xml.tag_rank
      Io_infer.Xml.tag_in_calls Io_infer.Xml.tag_out_calls Io_infer.Xml.tag_proof_trace


  (** Write proc summary stats in csv format *)
  let pp_summary fmt summary =
    let pp x = F.fprintf fmt x in
    let sv = summary_values summary in
    pp "\"%s\"," (Escape.escape_csv sv.vname) ;
    pp "\"%s\"," (Escape.escape_csv sv.vname_id) ;
    pp "%d," sv.vspecs ;
    pp "%s," sv.vto ;
    pp "%d," sv.vsymop ;
    pp "%d," sv.verr ;
    pp "%s," sv.vfile ;
    pp "%d," sv.vline ;
    pp "\"%s\"," (Escape.escape_csv sv.vsignature) ;
    pp "%s@\n" sv.vproof_trace

end

let should_report (issue_kind: Exceptions.err_kind) issue_type error_desc eclass =
  if not Config.filtering || Exceptions.equal_err_class eclass Exceptions.Linters then true
  else
    let issue_kind_is_blacklisted =
      match issue_kind with Kinfo -> true | Kerror | Kwarning | Kadvice | Klike -> false
    in
    if issue_kind_is_blacklisted then false
    else
      let issue_type_is_null_deref =
        let null_deref_issue_types =
          let open IssueType in
          [ field_not_null_checked
          ; null_dereference
          ; parameter_not_null_checked
          ; premature_nil_termination
          ; empty_vector_access ]
        in
        List.mem ~equal:IssueType.equal null_deref_issue_types issue_type
      in
      if issue_type_is_null_deref then
        let issue_bucket_is_high =
          let issue_bucket = Localise.error_desc_get_bucket error_desc in
          let high_buckets = Localise.BucketLevel.([b1; b2]) in
          Option.value_map issue_bucket ~default:false ~f:(fun b ->
              List.mem ~equal:String.equal high_buckets b )
        in
        issue_bucket_is_high
      else true


(* The reason an issue should be censored (that is, not reported). The empty
   string (that is "no reason") means that the issue should be reported. *)
let censored_reason (issue_type: IssueType.t) source_file =
  let filename = SourceFile.to_rel_path source_file in
  let rejected_by ((issue_type_polarity, issue_type_re), (filename_polarity, filename_re), reason) =
    let accepted =
      (* matches issue_type_re implies matches filename_re *)
      not (Bool.equal issue_type_polarity (Str.string_match issue_type_re issue_type.unique_id 0))
      || Bool.equal filename_polarity (Str.string_match filename_re filename 0)
    in
    Option.some_if (not accepted) reason
  in
  Option.value ~default:"" (List.find_map Config.filter_report ~f:rejected_by)


module IssuesCsv = struct
  let csv_issues_id = ref 0

  let pp_header fmt () =
    Format.fprintf fmt "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s@\n" Io_infer.Xml.tag_class
      Io_infer.Xml.tag_kind Io_infer.Xml.tag_type Io_infer.Xml.tag_qualifier
      Io_infer.Xml.tag_severity Io_infer.Xml.tag_line Io_infer.Xml.tag_procedure
      Io_infer.Xml.tag_procedure_id Io_infer.Xml.tag_file Io_infer.Xml.tag_trace
      Io_infer.Xml.tag_key Io_infer.Xml.tag_qualifier_tags Io_infer.Xml.tag_hash "bug_id"
      "always_report" "advice"


  let pp_issue fmt error_filter procname proc_loc_opt (key: Errlog.err_key)
      (err_data: Errlog.err_data) =
    let pp x = F.fprintf fmt x in
    let source_file =
      match proc_loc_opt with
      | Some proc_loc ->
          proc_loc.Location.file
      | None ->
          err_data.loc.Location.file
    in
    if key.in_footprint && error_filter source_file key.err_desc key.err_name
       && should_report key.err_kind key.err_name key.err_desc err_data.err_class
    then
      let err_desc_string = error_desc_to_csv_string key.err_desc in
      let err_advice_string = error_advice_to_csv_string key.err_desc in
      let qualifier_tag_xml =
        let xml_node =
          Io_infer.Xml.create_tree Io_infer.Xml.tag_qualifier_tags []
            (error_desc_to_xml_tags key.err_desc)
        in
        let p fmt = F.fprintf fmt "%a" (Io_infer.Xml.pp_document false) xml_node in
        let s = F.asprintf "%t" p in
        Escape.escape_csv s
      in
      let kind = Exceptions.err_kind_string key.err_kind in
      let type_str = key.err_name.IssueType.unique_id in
      let procedure_id = Typ.Procname.to_filename procname in
      let filename = SourceFile.to_string source_file in
      let always_report =
        match Localise.error_desc_extract_tag_value key.err_desc "always_report" with
        | "" ->
            "false"
        | v ->
            v
      in
      let trace =
        Jsonbug_j.string_of_json_trace
          {trace= loc_trace_to_jsonbug_record err_data.loc_trace key.err_kind}
      in
      incr csv_issues_id ;
      pp "%s," (Exceptions.err_class_string err_data.err_class) ;
      pp "%s," kind ;
      pp "%s," type_str ;
      pp "\"%s\"," err_desc_string ;
      pp "%s," key.severity ;
      pp "%d," err_data.loc.Location.line ;
      pp "\"%s\"," (Escape.escape_csv (Typ.Procname.to_string procname)) ;
      pp "\"%s\"," (Escape.escape_csv procedure_id) ;
      pp "%s," filename ;
      pp "\"%s\"," (Escape.escape_csv trace) ;
      pp "\"%s\"," (Digest.to_hex err_data.node_id_key.node_key) ;
      pp "\"%s\"," qualifier_tag_xml ;
      pp "\"%s\","
        ( get_bug_hash kind type_str procedure_id filename err_data.node_id_key.node_key
            key.err_desc
        |> Digest.to_hex ) ;
      pp "\"%d\"," !csv_issues_id ;
      (* bug id *)
      pp "\"%s\"," always_report ;
      pp "\"%s\"@\n" err_advice_string


  (** Write bug report in csv format *)
  let pp_issues_of_error_log fmt error_filter _ proc_loc_opt procname err_log =
    Errlog.iter (pp_issue fmt error_filter procname proc_loc_opt) err_log

end

let potential_exception_message = "potential exception at line"

module IssuesJson = struct
  let is_first_item = ref true

  let pp_json_open fmt () =
    is_first_item := true ;
    F.fprintf fmt "[@?"


  let pp_json_close fmt () = F.fprintf fmt "]@\n@?"

  let pp_issue fmt error_filter procname proc_loc_opt (key: Errlog.err_key)
      (err_data: Errlog.err_data) =
    let pp x = F.fprintf fmt x in
    let source_file, procedure_start_line =
      match proc_loc_opt with
      | Some proc_loc ->
          (proc_loc.Location.file, proc_loc.Location.line)
      | None ->
          (err_data.loc.Location.file, 0)
    in
    if SourceFile.is_invalid source_file then
      L.(die InternalError)
        "Invalid source file for %a %a@.Trace: %a@." IssueType.pp key.err_name
        Localise.pp_error_desc key.err_desc Errlog.pp_loc_trace err_data.loc_trace ;
    let should_report_source_file =
      not (SourceFile.is_infer_model source_file) || Config.debug_mode || Config.debug_exceptions
    in
    if key.in_footprint && error_filter source_file key.err_desc key.err_name
       && should_report_source_file
       && should_report key.err_kind key.err_name key.err_desc err_data.err_class
    then
      let kind = Exceptions.err_kind_string key.err_kind in
      let bug_type = key.err_name.IssueType.unique_id in
      let procedure_id = Typ.Procname.to_filename procname in
      let file = SourceFile.to_string source_file in
      let json_ml_loc =
        match err_data.loc_in_ml_source with
        | Some (file, lnum, cnum, enum) when Config.reports_include_ml_loc ->
            Some Jsonbug_j.{file; lnum; cnum; enum}
        | _ ->
            None
      in
      let visibility = Exceptions.string_of_visibility err_data.visibility in
      let qualifier =
        let base_qualifier = error_desc_to_plain_string key.err_desc in
        if IssueType.(equal resource_leak) key.err_name then
          match Errlog.compute_local_exception_line err_data.loc_trace with
          | None ->
              base_qualifier
          | Some line ->
              let potential_exception_message =
                Format.asprintf "%a: %s %d" MarkupFormatter.pp_bold "Note"
                  potential_exception_message line
              in
              Format.sprintf "%s@\n%s" base_qualifier potential_exception_message
        else base_qualifier
      in
      let bug =
        { Jsonbug_j.bug_class= Exceptions.err_class_string err_data.err_class
        ; kind
        ; bug_type
        ; qualifier
        ; severity= key.severity
        ; visibility
        ; line= err_data.loc.Location.line
        ; column= err_data.loc.Location.col
        ; procedure= Typ.Procname.to_string procname
        ; procedure_id
        ; procedure_start_line
        ; file
        ; bug_trace= loc_trace_to_jsonbug_record err_data.loc_trace key.err_kind
        ; key= err_data.node_id_key.node_key |> Digest.to_hex
        ; qualifier_tags= Localise.Tags.tag_value_records_of_tags key.err_desc.tags
        ; hash=
            get_bug_hash kind bug_type procedure_id file err_data.node_id_key.node_key key.err_desc
            |> Digest.to_hex
        ; dotty= error_desc_to_dotty_string key.err_desc
        ; infer_source_loc= json_ml_loc
        ; bug_type_hum= key.err_name.IssueType.hum
        ; linters_def_file= err_data.linters_def_file
        ; doc_url= err_data.doc_url
        ; traceview_id= None
        ; censored_reason= censored_reason key.err_name source_file }
      in
      if not !is_first_item then pp "," else is_first_item := false ;
      pp "%s@?" (Jsonbug_j.string_of_jsonbug bug)


  (** Write bug report in JSON format *)
  let pp_issues_of_error_log fmt error_filter _ proc_loc_opt procname err_log =
    Errlog.iter (pp_issue fmt error_filter procname proc_loc_opt) err_log

end

let pp_custom_of_report fmt report fields =
  let pp_custom_of_issue fmt issue =
    let open Jsonbug_t in
    let comma_separator index = if index > 0 then ", " else "" in
    let pp_trace fmt trace comma =
      let pp_trace_elem fmt {description} = F.fprintf fmt "%s" description in
      let trace_without_empty_descs =
        List.filter ~f:(fun {description} -> description <> "") trace
      in
      F.fprintf fmt "%s[%a]" comma (Pp.comma_seq pp_trace_elem) trace_without_empty_descs
    in
    let pp_field index field =
      match field with
      | `Issue_field_bug_class ->
          Format.fprintf fmt "%s%s" (comma_separator index) issue.bug_class
      | `Issue_field_kind ->
          Format.fprintf fmt "%s%s" (comma_separator index) issue.kind
      | `Issue_field_bug_type ->
          Format.fprintf fmt "%s%s" (comma_separator index) issue.bug_type
      | `Issue_field_qualifier ->
          Format.fprintf fmt "%s%s" (comma_separator index) issue.qualifier
      | `Issue_field_severity ->
          Format.fprintf fmt "%s%s" (comma_separator index) issue.severity
      | `Issue_field_visibility ->
          Format.fprintf fmt "%s%s" (comma_separator index) issue.visibility
      | `Issue_field_line ->
          Format.fprintf fmt "%s%d" (comma_separator index) issue.line
      | `Issue_field_column ->
          Format.fprintf fmt "%s%d" (comma_separator index) issue.column
      | `Issue_field_procedure ->
          Format.fprintf fmt "%s%s" (comma_separator index) issue.procedure
      | `Issue_field_procedure_id ->
          Format.fprintf fmt "%s%s" (comma_separator index) issue.procedure_id
      | `Issue_field_procedure_start_line ->
          Format.fprintf fmt "%s%d" (comma_separator index) issue.procedure_start_line
      | `Issue_field_file ->
          Format.fprintf fmt "%s%s" (comma_separator index) issue.file
      | `Issue_field_bug_trace ->
          pp_trace fmt issue.bug_trace (comma_separator index)
      | `Issue_field_key ->
          Format.fprintf fmt "%s%s" (comma_separator index) (Digest.to_hex issue.key)
      | `Issue_field_hash ->
          Format.fprintf fmt "%s%s" (comma_separator index) (Digest.to_hex issue.hash)
      | `Issue_field_line_offset ->
          Format.fprintf fmt "%s%d" (comma_separator index)
            (issue.line - issue.procedure_start_line)
      | `Issue_field_procedure_id_without_crc ->
          Format.fprintf fmt "%s%s" (comma_separator index) (DB.strip_crc issue.procedure_id)
      | `Issue_field_qualifier_contains_potential_exception_note ->
          Format.fprintf fmt "%B"
            (String.is_substring issue.qualifier ~substring:potential_exception_message)
    in
    List.iteri ~f:pp_field fields ; Format.fprintf fmt "@."
  in
  List.iter ~f:(pp_custom_of_issue fmt) report


let tests_jsonbug_compare bug1 bug2 =
  let open Jsonbug_t in
  [%compare : string * string * int * string * Digest.t]
    (bug1.file, bug1.procedure, bug1.line - bug1.procedure_start_line, bug1.bug_type, bug1.hash)
    (bug2.file, bug2.procedure, bug2.line - bug2.procedure_start_line, bug2.bug_type, bug2.hash)


module IssuesTxt = struct
  let pp_issue fmt error_filter proc_loc_opt (key: Errlog.err_key) (err_data: Errlog.err_data) =
    let source_file =
      match proc_loc_opt with
      | Some proc_loc ->
          proc_loc.Location.file
      | None ->
          err_data.loc.Location.file
    in
    if key.in_footprint && error_filter source_file key.err_desc key.err_name
       && (not Config.filtering || String.is_empty (censored_reason key.err_name source_file))
    then
      Exceptions.pp_err ~node_key:err_data.node_id_key.node_key err_data.loc key.err_kind
        key.err_name key.err_desc None fmt ()


  (** Write bug report in text format *)
  let pp_issues_of_error_log fmt error_filter _ proc_loc_opt _ err_log =
    Errlog.iter (pp_issue fmt error_filter proc_loc_opt) err_log

end

let pp_text_of_report fmt report =
  let pp_row jsonbug =
    let open Jsonbug_t in
    F.fprintf fmt "%s:%d: %s: %s %s@\n" jsonbug.file jsonbug.line jsonbug.kind jsonbug.bug_type
      jsonbug.qualifier
  in
  List.iter ~f:pp_row report ; F.fprintf fmt "@?"


module CallsCsv = struct
  (** Write proc summary stats in csv format *)
  let pp_calls fmt summary =
    let pp x = F.fprintf fmt x in
    let stats = summary.Specs.stats in
    let caller_name = Specs.get_proc_name summary in
    let do_call (callee_name, loc) trace =
      pp "\"%s\"," (Escape.escape_csv (Typ.Procname.to_string caller_name)) ;
      pp "\"%s\"," (Escape.escape_csv (Typ.Procname.to_filename caller_name)) ;
      pp "\"%s\"," (Escape.escape_csv (Typ.Procname.to_string callee_name)) ;
      pp "\"%s\"," (Escape.escape_csv (Typ.Procname.to_filename callee_name)) ;
      pp "%s," (SourceFile.to_string (Specs.get_loc summary).Location.file) ;
      pp "%d," loc.Location.line ;
      pp "%a@\n" Specs.CallStats.pp_trace trace
    in
    Specs.CallStats.iter do_call stats.Specs.call_stats

end

module Stats = struct
  type t =
    { files: (SourceFile.t, unit) Hashtbl.t
    ; mutable nchecked: int
    ; mutable ndefective: int
    ; mutable nerrors: int
    ; mutable ninfos: int
    ; mutable nadvice: int
    ; mutable nlikes: int
    ; mutable nprocs: int
    ; mutable nspecs: int
    ; mutable ntimeouts: int
    ; mutable nverified: int
    ; mutable nwarnings: int
    ; mutable saved_errors: string list }

  let create () =
    { files= Hashtbl.create 3
    ; nchecked= 0
    ; ndefective= 0
    ; nerrors= 0
    ; ninfos= 0
    ; nadvice= 0
    ; nlikes= 0
    ; nprocs= 0
    ; nspecs= 0
    ; ntimeouts= 0
    ; nverified= 0
    ; nwarnings= 0
    ; saved_errors= [] }


  let process_loc loc stats =
    try Hashtbl.find stats.files loc.Location.file with Not_found ->
      Hashtbl.add stats.files loc.Location.file ()


  let loc_trace_to_string_list linereader indent_num ltr =
    let res = ref [] in
    let indent_string n =
      let s = ref "" in
      for _ = 1 to n do s := "  " ^ !s done ;
      !s
    in
    let num = ref 0 in
    let loc_to_string lt =
      incr num ;
      let loc = lt.Errlog.lt_loc in
      let level = lt.Errlog.lt_level in
      let description = lt.Errlog.lt_description in
      let code =
        match Printer.LineReader.from_loc linereader loc with Some s -> s | None -> ""
      in
      let line =
        let pp fmt =
          if description <> "" then
            F.fprintf fmt "%s%4s  // %s@\n" (indent_string (level + indent_num)) " " description ;
          F.fprintf fmt "%s%04d: %s" (indent_string (level + indent_num)) loc.Location.line code
        in
        F.asprintf "%t" pp
      in
      res := line :: "" :: !res
    in
    List.iter ~f:loc_to_string ltr ;
    List.rev !res


  let process_err_log error_filter linereader err_log stats =
    let found_errors = ref false in
    let process_row (key: Errlog.err_key) (err_data: Errlog.err_data) =
      let type_str = key.err_name.IssueType.unique_id in
      if key.in_footprint && error_filter key.err_desc key.err_name then
        match key.err_kind with
        | Exceptions.Kerror ->
            found_errors := true ;
            stats.nerrors <- stats.nerrors + 1 ;
            let error_strs =
              let pp1 fmt = F.fprintf fmt "%d: %s" stats.nerrors type_str in
              let pp2 fmt =
                F.fprintf fmt "  %a:%d" SourceFile.pp err_data.loc.Location.file
                  err_data.loc.Location.line
              in
              let pp3 fmt = F.fprintf fmt "  (%a)" Localise.pp_error_desc key.err_desc in
              [F.asprintf "%t" pp1; F.asprintf "%t" pp2; F.asprintf "%t" pp3]
            in
            let trace = loc_trace_to_string_list linereader 1 err_data.loc_trace in
            stats.saved_errors <- List.rev_append (error_strs @ trace @ [""]) stats.saved_errors
        | Exceptions.Kwarning ->
            stats.nwarnings <- stats.nwarnings + 1
        | Exceptions.Kinfo ->
            stats.ninfos <- stats.ninfos + 1
        | Exceptions.Kadvice ->
            stats.nadvice <- stats.nadvice + 1
        | Exceptions.Klike ->
            stats.nlikes <- stats.nlikes + 1
    in
    Errlog.iter process_row err_log ; !found_errors


  let process_summary error_filter summary linereader stats =
    let specs = Specs.get_specs_from_payload summary in
    let found_errors = process_err_log error_filter linereader (Specs.get_err_log summary) stats in
    let is_defective = found_errors in
    let is_verified = specs <> [] && not is_defective in
    let is_checked = not (is_defective || is_verified) in
    let is_timeout =
      match Specs.(summary.stats.stats_failure) with None | Some FKcrash _ -> false | _ -> true
    in
    stats.nprocs <- stats.nprocs + 1 ;
    stats.nspecs <- stats.nspecs + List.length specs ;
    if is_verified then stats.nverified <- stats.nverified + 1 ;
    if is_checked then stats.nchecked <- stats.nchecked + 1 ;
    if is_timeout then stats.ntimeouts <- stats.ntimeouts + 1 ;
    if is_defective then stats.ndefective <- stats.ndefective + 1 ;
    process_loc (Specs.get_loc summary) stats


  let num_files stats = Hashtbl.length stats.files

  let pp fmt stats =
    F.fprintf fmt "Files: %d@\n" (num_files stats) ;
    F.fprintf fmt "Specs: %d@\n" stats.nspecs ;
    F.fprintf fmt "Timeouts: %d@\n" stats.ntimeouts ;
    F.fprintf fmt "Procedures: %d@\n" stats.nprocs ;
    F.fprintf fmt "  Verified: %d@\n" stats.nverified ;
    F.fprintf fmt "  Checked: %d@\n" stats.nchecked ;
    F.fprintf fmt "  Defective: %d@\n" stats.ndefective ;
    F.fprintf fmt "Errors: %d@\n" stats.nerrors ;
    F.fprintf fmt "Warnings: %d@\n" stats.nwarnings ;
    F.fprintf fmt "Infos: %d@\n" stats.ninfos ;
    F.fprintf fmt "@\n -------------------@\n" ;
    F.fprintf fmt "@\nDetailed Errors@\n@\n" ;
    List.iter ~f:(fun s -> F.fprintf fmt "%s@\n" s) (List.rev stats.saved_errors)

end

module Report = struct
  let pp_header fmt () =
    F.fprintf fmt "Infer Analysis Results -- generated %a@\n@\n" Pp.current_time () ;
    F.fprintf fmt "Summary Report@\n@\n"


  let pp_stats fmt stats = Stats.pp fmt stats
end

(** Categorize the preconditions of specs and print stats *)
module PreconditionStats = struct
  let nr_nopres = ref 0

  let nr_empty = ref 0

  let nr_onlyallocation = ref 0

  let nr_dataconstraints = ref 0

  let do_summary proc_name summary =
    let specs = Specs.get_specs_from_payload summary in
    let preconditions = List.map ~f:(fun spec -> Specs.Jprop.to_prop spec.Specs.pre) specs in
    match Prop.CategorizePreconditions.categorize preconditions with
    | Prop.CategorizePreconditions.Empty ->
        incr nr_empty ;
        L.result "Procedure: %a footprint:Empty@." Typ.Procname.pp proc_name
    | Prop.CategorizePreconditions.OnlyAllocation ->
        incr nr_onlyallocation ;
        L.result "Procedure: %a footprint:OnlyAllocation@." Typ.Procname.pp proc_name
    | Prop.CategorizePreconditions.NoPres ->
        incr nr_nopres ;
        L.result "Procedure: %a footprint:NoPres@." Typ.Procname.pp proc_name
    | Prop.CategorizePreconditions.DataConstraints ->
        incr nr_dataconstraints ;
        L.result "Procedure: %a footprint:DataConstraints@." Typ.Procname.pp proc_name


  let pp_stats () =
    L.result "@.Precondition stats@." ;
    L.result "Procedures with no preconditions: %d@." !nr_nopres ;
    L.result "Procedures with empty precondition: %d@." !nr_empty ;
    L.result "Procedures with only allocation conditions: %d@." !nr_onlyallocation ;
    L.result "Procedures with data constraints: %d@." !nr_dataconstraints

end

(* Wrapper of an issue that compares all parts except the procname *)
module Issue = struct
  type err_data_ = Errlog.err_data

  (* no derived compare for err_data; just compare the locations *)
  let compare_err_data_ (err_data1: Errlog.err_data) (err_data2: Errlog.err_data) =
    Location.compare err_data1.loc err_data2.loc


  type proc_name_ = Typ.Procname.t

  (* ignore proc name *)
  let compare_proc_name_ _ _ = 0

  type t =
    {proc_name: proc_name_; proc_location: Location.t; err_key: Errlog.err_key; err_data: err_data_}
    [@@deriving compare]

  (* If two issues are identical except for their procnames, they are probably duplicate reports on
     two different instantiations of the same template. We don't want to spam users by reporting
     identical warning on the same line. Accomplish this by sorting without regard to procname, then
     de-duplicating. *)
  let sort_filter_issues issues =
    let issues' = List.dedup ~compare issues in
    ( if Config.developer_mode then
        let num_pruned_issues = List.length issues - List.length issues' in
        if num_pruned_issues > 0 then
          L.user_warning "Note: pruned %d duplicate issues@\n" num_pruned_issues ) ;
    issues'

end

let error_filter filters proc_name file error_desc error_name =
  let always_report () =
    String.equal (Localise.error_desc_extract_tag_value error_desc "always_report") "true"
  in
  (Config.write_html || not (IssueType.(equal skip_function) error_name))
  && (filters.Inferconfig.path_filter file || always_report ())
  && filters.Inferconfig.error_filter error_name && filters.Inferconfig.proc_filter proc_name


type report_kind = Issues | Procs | Stats | Calls [@@deriving compare]

type bug_format_kind = Json | Csv | Tests | Text [@@deriving compare]

let pp_issue_in_format (format_kind, (outf: Utils.outfile)) error_filter
    {Issue.proc_name; proc_location; err_key; err_data} =
  match format_kind with
  | Csv ->
      IssuesCsv.pp_issue outf.fmt error_filter proc_name (Some proc_location) err_key err_data
  | Json ->
      IssuesJson.pp_issue outf.fmt error_filter proc_name (Some proc_location) err_key err_data
  | Tests ->
      L.(die InternalError) "Print issues as tests is not implemented"
  | Text ->
      IssuesTxt.pp_issue outf.fmt error_filter (Some proc_location) err_key err_data


let pp_issues_in_format (format_kind, (outf: Utils.outfile)) =
  match format_kind with
  | Json ->
      IssuesJson.pp_issues_of_error_log outf.fmt
  | Csv ->
      IssuesCsv.pp_issues_of_error_log outf.fmt
  | Tests ->
      L.(die InternalError) "Print issues as tests is not implemented"
  | Text ->
      IssuesTxt.pp_issues_of_error_log outf.fmt


let pp_procs_in_format (format_kind, (outf: Utils.outfile)) =
  match format_kind with
  | Csv ->
      ProcsCsv.pp_summary outf.fmt
  | Json | Tests | Text ->
      L.(die InternalError) "Printing procs in json/tests/text is not implemented"


let pp_calls_in_format (format_kind, (outf: Utils.outfile)) =
  match format_kind with
  | Csv ->
      CallsCsv.pp_calls outf.fmt
  | Json | Tests | Text ->
      L.(die InternalError) "Printing calls in json/tests/text is not implemented"


let pp_stats_in_format (format_kind, _) =
  match format_kind with
  | Csv ->
      Stats.process_summary
  | Json | Tests | Text ->
      L.(die InternalError) "Printing stats in json/tests/text is not implemented"


let pp_issues_of_error_log error_filter linereader proc_loc_opt procname err_log bug_format_list =
  let pp_issues_in_format format =
    pp_issues_in_format format error_filter linereader proc_loc_opt procname err_log
  in
  List.iter ~f:pp_issues_in_format bug_format_list


let collect_issues summary issues_acc =
  let err_log = Specs.get_err_log summary in
  let proc_name = Specs.get_proc_name summary in
  let proc_location = Specs.get_loc summary in
  Errlog.fold
    (fun err_key err_data acc -> {Issue.proc_name; proc_location; err_key; err_data} :: acc)
    err_log issues_acc


let pp_procs summary procs_format_list =
  let pp_procs_in_format format =
    let pp_procs = pp_procs_in_format format in
    pp_procs summary
  in
  List.iter ~f:pp_procs_in_format procs_format_list


let pp_calls summary calls_format_list =
  let pp_calls_in_format format =
    let pp_calls = pp_calls_in_format format in
    pp_calls summary
  in
  List.iter ~f:pp_calls_in_format calls_format_list


let pp_stats error_filter linereader summary stats stats_format_list =
  let pp_stats_in_format format =
    let pp_stats = pp_stats_in_format format in
    pp_stats error_filter summary linereader stats
  in
  List.iter ~f:pp_stats_in_format stats_format_list


let pp_summary_by_report_kind formats_by_report_kind summary error_filter linereader stats file
    issues_acc =
  let pp_summary_by_report_kind (report_kind, format_list) =
    match (report_kind, format_list) with
    | Procs, _ :: _ ->
        pp_procs summary format_list
    | Stats, _ :: _ ->
        pp_stats (error_filter file) linereader summary stats format_list
    | Calls, _ :: _ ->
        pp_calls summary format_list
    | _ ->
        ()
  in
  List.iter ~f:pp_summary_by_report_kind formats_by_report_kind ;
  collect_issues summary issues_acc


let pp_json_report_by_report_kind formats_by_report_kind fname =
  match Utils.read_file fname with
  | Ok report_lines ->
      let pp_json_issues format_list report =
        let pp_json_issue (format_kind, (outf: Utils.outfile)) =
          match format_kind with
          | Tests ->
              pp_custom_of_report outf.fmt report Config.issues_fields
          | Text ->
              pp_text_of_report outf.fmt report
          | Json ->
              L.(die InternalError) "Printing issues from json does not support json output"
          | Csv ->
              L.(die InternalError) "Printing issues from json does not support csv output"
        in
        List.iter ~f:pp_json_issue format_list
      in
      let sorted_report =
        let report = Jsonbug_j.report_of_string (String.concat ~sep:"\n" report_lines) in
        List.sort ~cmp:tests_jsonbug_compare report
      in
      let pp_report_by_report_kind (report_kind, format_list) =
        match (report_kind, format_list) with
        | Issues, _ :: _ ->
            pp_json_issues format_list sorted_report
        | _ ->
            ()
      in
      List.iter ~f:pp_report_by_report_kind formats_by_report_kind
  | Error error ->
      L.(die UserError) "Error reading '%s': %s" fname error


let pp_lint_issues_by_report_kind formats_by_report_kind error_filter linereader procname error_log =
  let pp_summary_by_report_kind (report_kind, format_list) =
    match (report_kind, format_list) with
    | Issues, _ :: _ ->
        pp_issues_of_error_log error_filter linereader None procname error_log format_list
    | _ ->
        ()
  in
  List.iter ~f:pp_summary_by_report_kind formats_by_report_kind


(** Process lint issues of a procedure *)
let pp_lint_issues filters formats_by_report_kind linereader procname error_log =
  let error_filter = error_filter filters procname in
  pp_lint_issues_by_report_kind formats_by_report_kind error_filter linereader procname error_log


(** Process a summary *)
let process_summary filters formats_by_report_kind linereader stats summary issues_acc =
  let file = (Specs.get_loc summary).Location.file in
  let proc_name = Specs.get_proc_name summary in
  let error_filter = error_filter filters proc_name in
  let pp_simple_saved = !Config.pp_simple in
  Config.pp_simple := true ;
  let issues_acc' =
    pp_summary_by_report_kind formats_by_report_kind summary error_filter linereader stats file
      issues_acc
  in
  if Config.precondition_stats then PreconditionStats.do_summary proc_name summary ;
  Config.pp_simple := pp_simple_saved ;
  issues_acc'


module AnalysisResults = struct
  type t = (string * Specs.summary) list

  let spec_files_from_cmdline () =
    if CLOpt.is_originator then (
      (* Find spec files specified by command-line arguments.  Not run at init time since the specs
         files may be generated between init and report time. *)
      List.iter
        ~f:(fun arg ->
          if not (Filename.check_suffix arg Config.specs_files_suffix) && arg <> "." then
            print_usage_exit ("file " ^ arg ^ ": arguments must be .specs files"))
        Config.anon_args ;
      if Config.test_filtering then ( Inferconfig.test () ; L.exit 0 ) ;
      if List.is_empty Config.anon_args then load_specfiles () else List.rev Config.anon_args )
    else load_specfiles ()


  (** Load .specs files in memory and return list of summaries *)
  let load_summaries_in_memory () : t =
    let summaries = ref [] in
    let load_file fname =
      match Specs.load_summary (DB.filename_from_string fname) with
      | None ->
          L.(die UserError) "Error: cannot open file %s@." fname
      | Some summary ->
          summaries := (fname, summary) :: !summaries
    in
    let do_load () = spec_files_from_cmdline () |> List.iter ~f:load_file in
    Utils.without_gc ~f:do_load ;
    let summ_cmp (_, summ1) (_, summ2) =
      let loc1 = Specs.get_loc summ1 and loc2 = Specs.get_loc summ2 in
      let n = SourceFile.compare loc1.Location.file loc2.Location.file in
      if n <> 0 then n else Int.compare loc1.Location.line loc2.Location.line
    in
    List.sort ~cmp:summ_cmp !summaries


  (** Create an iterator which loads spec files one at a time *)
  let iterator_of_spec_files () =
    let sorted_spec_files = List.sort ~cmp:String.compare (spec_files_from_cmdline ()) in
    let do_spec f fname =
      match Specs.load_summary (DB.filename_from_string fname) with
      | None ->
          L.(die UserError) "Error: cannot open file %s@." fname
      | Some summary ->
          f (fname, summary)
    in
    let iterate f = List.iter ~f:(do_spec f) sorted_spec_files in
    iterate


  (** Serializer for analysis results *)
  let analysis_results_serializer : t Serialization.serializer =
    Serialization.create_serializer Serialization.Key.analysis_results


  (** Load analysis_results from a file *)
  let load_analysis_results_from_file (filename: DB.filename) : t option =
    Serialization.read_from_file analysis_results_serializer filename


  (** Save analysis_results into a file *)
  let store_analysis_results_to_file (filename: DB.filename) (analysis_results: t) =
    Serialization.write_to_file analysis_results_serializer filename ~data:analysis_results


  (** Return an iterator over all the summaries.
      If options - load_results or - save_results are used,
      all the summaries are loaded in memory *)
  let get_summary_iterator () =
    let iterator_of_summary_list r f = List.iter ~f r in
    match Config.load_analysis_results with
    | None -> (
      match Config.save_analysis_results with
      | None ->
          iterator_of_spec_files ()
      | Some s ->
          let r = load_summaries_in_memory () in
          store_analysis_results_to_file (DB.filename_from_string s) r ;
          iterator_of_summary_list r )
    | Some fname ->
      match load_analysis_results_from_file (DB.filename_from_string fname) with
      | Some r ->
          iterator_of_summary_list r
      | None ->
          L.(die UserError) "Error: cannot open analysis results file %s@." fname

end

let register_perf_stats_report () =
  let stats_dir = Filename.concat Config.results_dir Config.reporting_stats_dir_name in
  let stats_file = Filename.concat stats_dir (Config.perf_stats_prefix ^ ".json") in
  PerfStats.register_report_at_exit stats_file


let mk_format format_kind fname =
  Option.value_map
    ~f:(fun out_file -> [(format_kind, out_file)])
    ~default:[] (Utils.create_outfile fname)


let init_issues_format_list report_csv report_json =
  let csv_format = Option.value_map ~f:(mk_format Csv) ~default:[] report_csv in
  let json_format = Option.value_map ~f:(mk_format Json) ~default:[] report_json in
  let tests_format = Option.value_map ~f:(mk_format Tests) ~default:[] Config.issues_tests in
  let txt_format = Option.value_map ~f:(mk_format Text) ~default:[] Config.issues_txt in
  csv_format @ json_format @ tests_format @ txt_format


let init_procs_format_list () = Option.value_map ~f:(mk_format Csv) ~default:[] Config.procs_csv

let init_calls_format_list () =
  let csv_format = Option.value_map ~f:(mk_format Csv) ~default:[] Config.calls_csv in
  csv_format


let init_stats_format_list () =
  let csv_format = Option.value_map ~f:(mk_format Csv) ~default:[] Config.stats_report in
  csv_format


let init_files format_list_by_kind =
  let init_files_of_report_kind (report_kind, format_list) =
    let init_files_of_format (format_kind, (outfile: Utils.outfile)) =
      match (format_kind, report_kind) with
      | Csv, Issues ->
          IssuesCsv.pp_header outfile.fmt ()
      | Csv, Procs ->
          ProcsCsv.pp_header outfile.fmt ()
      | Csv, Stats ->
          Report.pp_header outfile.fmt ()
      | Json, Issues ->
          IssuesJson.pp_json_open outfile.fmt ()
      | (Csv | Json | Tests | Text), _ ->
          ()
    in
    List.iter ~f:init_files_of_format format_list
  in
  List.iter ~f:init_files_of_report_kind format_list_by_kind


let finalize_and_close_files format_list_by_kind stats =
  let close_files_of_report_kind (report_kind, format_list) =
    let close_files_of_format (format_kind, (outfile: Utils.outfile)) =
      ( match (format_kind, report_kind) with
      | Csv, Stats ->
          F.fprintf outfile.fmt "%a@?" Report.pp_stats stats
      | Json, Issues ->
          IssuesJson.pp_json_close outfile.fmt ()
      | (Csv | Tests | Text | Json), _ ->
          () ) ;
      Utils.close_outf outfile
    in
    List.iter ~f:close_files_of_format format_list ;
    ()
  in
  List.iter ~f:close_files_of_report_kind format_list_by_kind


let pp_summary_and_issues formats_by_report_kind issue_formats =
  let stats = Stats.create () in
  let linereader = Printer.LineReader.create () in
  let filters = Inferconfig.create_filters Config.analyzer in
  let iterate_summaries = AnalysisResults.get_summary_iterator () in
  let all_issues = ref [] in
  iterate_summaries (fun (_, summary) ->
      all_issues
      := process_summary filters formats_by_report_kind linereader stats summary !all_issues ) ;
  List.iter
    ~f:(fun ({Issue.proc_name} as issue) ->
      let error_filter = error_filter filters proc_name in
      List.iter
        ~f:(fun issue_format -> pp_issue_in_format issue_format error_filter issue)
        issue_formats)
    (Issue.sort_filter_issues !all_issues) ;
  if Config.precondition_stats then PreconditionStats.pp_stats () ;
  LintIssues.load_issues_to_errlog_map Config.lint_issues_dir_name ;
  Typ.Procname.Map.iter
    (pp_lint_issues filters formats_by_report_kind linereader)
    !LintIssues.errLogMap ;
  finalize_and_close_files formats_by_report_kind stats


let main ~report_csv ~report_json =
  let issue_formats = init_issues_format_list report_csv report_json in
  let formats_by_report_kind =
    [ (Issues, issue_formats)
    ; (Procs, init_procs_format_list ())
    ; (Calls, init_calls_format_list ())
    ; (Stats, init_stats_format_list ()) ]
  in
  if Config.developer_mode then register_perf_stats_report () ;
  init_files formats_by_report_kind ;
  match Config.from_json_report with
  | Some fname ->
      pp_json_report_by_report_kind formats_by_report_kind fname
  | None ->
      pp_summary_and_issues formats_by_report_kind issue_formats
