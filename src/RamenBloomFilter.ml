(* Small Bloom Filter for the novelty operator. *)
open Batteries
open RamenLog

(* TODO: use RamenBitmask *)
type t =
  { bytes : Bytes.t ;
    nb_bits : int ; nb_keys : int ;
    salt : int list ;
    mutable nb_bits_set : int }

let make nb_bits nb_keys =
  let max_int_for_random = 0x3FFFFFFF in
  let len = (nb_bits + 7)/ 8 in
  { bytes = Bytes.make len (Char.chr 0) ;
    nb_bits ; nb_keys ; nb_bits_set = 0 ;
    salt = List.init nb_keys (fun _ -> Random.int max_int_for_random) }

let bit_loc_of_bit b =
  b lsr 3, b land 7

let get_bit t b =
  let idx, b_off = bit_loc_of_bit b in
  let n = Bytes.get t.bytes idx |> Char.code in
  (n lsr b_off) land 1 = 1

let fill_ratio t =
  float_of_int t.nb_bits_set /. float_of_int t.nb_bits

let false_positive_likelihood t =
  let k = float_of_int t.nb_keys in
  (1. -. exp ~-.(k *. fill_ratio t)) ** k

let set_bit t b =
  let idx, b_off = bit_loc_of_bit b in
  let n = Bytes.get t.bytes idx |> Char.code in
  let mask = 1 lsl b_off in
  if n land mask = 0 then (
    t.nb_bits_set <- t.nb_bits_set + 1 ;
    Bytes.set t.bytes idx (Char.chr (n lor (1 lsl b_off)))
  )

(*$= get_bit & ~printer:(BatIO.to_string BatBool.print)
  false (let t = make 1 1 in get_bit t 0)
  true (let t = make 1 1 in set_bit t 0 ; get_bit t 0)
  true (let t = make 10 1 in set_bit t 9 ; get_bit t 9)
  false (let t = make 10 1 in set_bit t 9 ; get_bit t 5)
 *)

type key = int list

let key t x =
  let h0 = Hashtbl.hash x in
  List.fold_left (fun prev_h salt ->
    let h = Hashtbl.hash (salt :: prev_h) in
    h :: prev_h) [h0] t.salt

let get_by_key t k =
  List.exists (fun h ->
    let b = h mod t.nb_bits in
    not (get_bit t b)) k |> not

let get t x =
  let k = key t x in
  get_by_key t k

let set_by_key t k =
  List.iter (fun h ->
    let b = h mod t.nb_bits in
    set_bit t b) k

let set t x =
  let k = key t x in
  set_by_key t k

(*$inject
  let t =
    let t = make 100 2 in
    set t "foo" ;
    set t "bar" ;
    t
 *)
(*$= get & ~printer:(BatIO.to_string BatBool.print)
  true (get t "foo")
  true (get t "bar")
  false (get t "baz")
 *)

(* Now for the slicing *)

type slice =
  { filter : t ;
    start_time : float }

type sliced_filter =
  { slices : slice array ;
    slice_width : float ;
    mutable current : int }

let make_slice nb_bits nb_keys start_time =
  { filter = make nb_bits nb_keys ; start_time }

(* We aim for a probability of false positive below 1.5%.  So we want 8.7 bits
 * per bit set, and 6 keys.  Thus [nb_bits] is nothing but an initial * guesses
 * that will be enlarged if needed *)
let nb_keys = 6
let nb_bits_per_bit_set = 8.7

let make_sliced start_time nb_slices slice_width nb_bits =
  { slices = Array.init nb_slices (fun i ->
      let start_time = start_time +. float_of_int i *. slice_width in
      make_slice nb_bits nb_keys start_time) ;
    slice_width ; current = 0 }

(* Tells if x has been seen earlier (and remember it). If x time is
 * before the range of remembered data returns false (not seen). *)
let remember sf time x =
  (* Should we rotate? *)
  let rec loop () =
    let end_time =
      sf.slices.(sf.current).start_time +. sf.slice_width in
    if time >= end_time then (
      sf.current <- (sf.current + 1) mod Array.length sf.slices ;
      (* Given the number of bit sets, maybe enlarge the hash *)
      let fr = fill_ratio sf.slices.(sf.current).filter in
      let fpl = false_positive_likelihood sf.slices.(sf.current).filter in
      let epsilon = 1e-9 in
      let minmax mi (x : float) ma =
        if x < mi then mi else if x > ma then ma else x in
      let nb_inserted s =
        let estimated =
          ~-. (float_of_int s.filter.nb_bits /. float_of_int nb_keys) *.
              log (1. -. (minmax epsilon (fill_ratio s.filter) (1. -. epsilon))) in
        max estimated (float_of_int s.filter.nb_bits_set) in
      let nb_inserted = Array.fold_left (fun n s ->
          max (nb_inserted s) n) 0. sf.slices in
      let nb_bits = nb_bits_per_bit_set *. nb_inserted |>
                    int_of_float |>
                    max 1024 in
      (* Avoid decreasing too fast *)
      let nb_bits =
        if nb_bits >= sf.slices.(sf.current).filter.nb_bits then nb_bits
        else (nb_bits + sf.slices.(sf.current).filter.nb_bits) / 2 in
      (if fr > 0.6 then !logger.info else !logger.debug)
        "Rotating bloom-filter, expunging filter %d filled up to %.02f%% \
         (%d/%d bits set, max of %d inserted items in all slices (estimated), \
         %.02f%% false positives), next size will be %d bits"
        sf.current (100. *. fr)
        sf.slices.(sf.current).filter.nb_bits_set
        sf.slices.(sf.current).filter.nb_bits
        (int_of_float nb_inserted)
        (100. *. fpl) nb_bits ;
      (* TODO: a slice_reset that does not allocate (if we keep a close size *)
      sf.slices.(sf.current) <- make_slice nb_bits nb_keys end_time ;
      loop ()
    ) in
  loop () ;
  (* TODO: early exit *)
  let rem =
    Array.fold_left (fun rem slice ->
      let rem = rem || get slice.filter x in
      if time >= slice.start_time && time < slice.start_time +. sf.slice_width then
        set slice.filter x
      ;
      rem) false sf.slices in
  rem