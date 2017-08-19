(* Function related to IPv6 addresses *)
open Batteries
open Stdint

let print fmt n =
  let mask = Uint128.of_int 65535 in
  let digit shf =
    Uint128.(shift_right_logical n shf |>
             logand mask |>
             to_int) in
  (* TODO: longest sequence of 0 (but more than a single word)
   * should be omitted *)
  for d = 0 to 7 do
    Printf.fprintf fmt "%s%x"
      (if d > 0 then ":" else "")
      (digit (112 - d*16))
  done
(*$= print & ~printer:(fun x -> x)
  "2001:db8:0:0:0:ff00:42:8329" \
    (BatIO.to_string print (Stdint.Uint128.of_string \
      "0x20010DB8000000000000FF0000428329"))
 *)

module Parser =
struct
  open RamenParsing

  let p m =
    let m = "IPv6" :: m in
    let group =
      let max_num = Num.of_int 65535 in
      non_decimal_integer 16 (return ()) hexadecimal_digit >>: fun n ->
      if Num.gt_num n max_num then
        raise (Reject "IPv6 group too large") ;
      Num.to_int n in
    let sep = char ':' in
    let ipv6_of_list lst =
      let rec loop n shf = function
      | [] -> assert (shf < 0) ; n
      | g :: rest ->
        let n = Uint128.(logor n (shift_left (of_int g) shf)) in
        loop n (shf - 16) rest
      in
      loop Uint128.zero 112 lst
    in
    (repeat ~min:8 ~max:8 ~sep group >>: ipv6_of_list |||
     (repeat ~max:7 ~sep group +- string "::" ++
      repeat ~max:7 ~sep group >>: fun (bef, aft) ->
        let len = List.length bef + List.length aft in
        if len > 8 then
          raise (Reject "IPv6 address too large") ;
        bef @ List.make (8 - len) 0 @ aft |> ipv6_of_list)
    ) m
end

let of_string = RamenParsing.of_string_exn Parser.p
(*$= of_string & ~printer:(BatIO.to_string print)
   (Stdint.Uint128.of_string "0x20010DB8000000000000FF0000428329") \
     (of_string "2001:db8::ff00:42:8329")
 *)

module Cidr =
struct
  (*$< Cidr *)
  type t = Uint128.t * int

  let netmask_of_len len =
    let shf = 128 - len in
    Uint128.(shift_left max_int shf)

  let and_to_len len net =
    Uint128.(logand (netmask_of_len len) net)

  let or_to_len len net =
    let shf = 128 - len in
    Uint128.(logor net ((shift_left one shf) - one))

  let print fmt (net, len) =
    let net = and_to_len len net in
    Printf.fprintf fmt "%a/%d" print net len
  (*$= print & ~printer:(fun x -> x)
     "2001:db8:0:0:0:ff00:42:8300/120" \
       (BatIO.to_string print \
         (Stdint.Uint128.of_string "0x20010DB8000000000000FF0000428300", 120))
   *)

  module Parser =
  struct
    open RamenParsing

    let small_int =
      unsigned_decimal_number >>: fun n ->
      if Num.gt_num n (Num.of_int 128) then
        raise (Reject "CIDRv6 width too large") ;
      Num.to_int n

    let p m =
      let m = "CIDRv6" :: m in
      (Parser.p +- char '/' ++ small_int >>: fun (net, len) ->
       and_to_len len net, len) m
  end

  let of_string = RamenParsing.of_string_exn Parser.p
  (*$= of_string & ~printer:(BatIO.to_string print)
     (Stdint.Uint128.of_string "0x20010DB8000000000000FF0000428300", 120) \
       (of_string "2001:db8::ff00:42:8300/120")
     (Stdint.Uint128.of_string "0x20010DB8000000000000FF0000428300", 120) \
       (of_string "2001:db8::ff00:42:8342/120")
   *)
  (*$>*)
end