open Canonical
open Utils
open Astutils
open Check


module LitPrepend : EXPRCHECK = struct
  type ctxt = Parsetree.expression_desc Pctxt.pctxt
  let fix = "using `::` instead"
  let violation = "using `@` to prepend an element to a list"
  let check st (E {location; source; pattern} : ctxt) =
    begin match pattern with
      | Pexp_apply (application, [(_, lop); _]) ->
        if application =~ "@" && is_singleton_list lop then
          let raw = IOUtils.code_at_loc location source in
          st := Hint.mk_hint location raw fix violation :: !st
      | _ -> ()
    end
end


module TupleProj : EXPRCHECK = struct
  type ctxt = Parsetree.expression_desc Pctxt.pctxt
  let fix = "using a let pattern match statement instead"
  let violation = "using fst / snd to project values out of a tuple"
  let check st (E {location; source; pattern} : ctxt) =
    begin match pattern with
      | Pexp_apply (application, [_]) ->
        if application =~ "fst" || application =~ "snd" then
          st := Hint.mk_hint location source fix violation :: !st
      | _ -> ()
    end
end

module NestedIf : EXPRCHECK = struct
  type ctxt = Parsetree.expression_desc Pctxt.pctxt
  let fix = "using let statements or helper methods / rethinking logic"
  let violation = "using nested if statements more than three layers deep"
  let check st (E {location; source; pattern} : ctxt) =
    let rec uses_same_var cond bthen belse = 
      begin match bthen with 
        | Pexp_ifthenelse (cond', bthen', Some belse') -> (*todo*) true
        | _ -> true
      end
    in 
    begin match pattern with
    | Pexp_ifthenelse (cond, bthen, Some belse) ->
      if uses_same_var cond bthen belse then () else
      let lside = match get_branches bthen with | Some (e1, e2) -> [e1;e2] | None -> [] in
      let rside = match get_branches belse with | Some (e1, e2) -> [e1; e2] | None -> [] in
      let branches_three = (lside @ rside) |>
                           List.map (fun (e: Parsetree.expression) -> skip_seq_let e) |> 
                           List.exists (
                             fun (e: Parsetree.expression) -> match e.pexp_desc with
                               | Parsetree.Pexp_ifthenelse (_) -> true
                               | _ -> false
                             ) in
      if branches_three then
        st := Hint.mk_hint location source fix violation :: !st
    | _ -> ()
    end
end

module NestedMatch : EXPRCHECK = struct
  type ctxt = Parsetree.expression_desc Pctxt.pctxt
  let fix = "using let statements or helper methods / rethinking logic"
  let violation = "using nested match statements more than three layers deep"
  let check st (E {location; source; pattern} : ctxt) =
    begin match pattern with
      (* Layer one *)
      | Pexp_match (_, cs) ->
        let matches_three = List.map (fun (c: Parsetree.case) -> c.pc_rhs |> skip_seq_let) cs |>
                     (* Grab the second layer *)
                     List.map (fun (e: Parsetree.expression) ->
                         match e.pexp_desc with
                         | Pexp_match (_, cs) ->
                           List.map (fun (c: Parsetree.case) -> c.pc_rhs |> skip_seq_let) cs
                         | _ -> []
                       ) |> List.flatten |>
                       (* Grab the third layer *)
                       List.exists (fun (e: Parsetree.expression) ->
                           match e.pexp_desc with
                           | Pexp_match _ -> true
                           | _ -> false ) in
        if matches_three then
          st := Hint.mk_hint location source fix violation :: !st
      | _ -> ()
    end
end


module IfReturnsLit : EXPRCHECK = struct
  type ctxt = Parsetree.expression_desc Pctxt.pctxt
  let fix = "returning just the condition (+ some tweaks)"
  let violation = "using an if statement to return `true | false` literally"
  let check st (E {location; source; pattern} : ctxt) =
    begin match pattern with
      | Pexp_ifthenelse (_, bthen, Some belse) ->
        if (bthen =| "true" && belse =| "false") ||
           (bthen =| "false" && belse =| "true") then
          st := Hint.mk_hint location source fix violation :: !st
      | _ -> ()
    end
end


module IfCondThenCond : EXPRCHECK = struct
  type ctxt = Parsetree.expression_desc Pctxt.pctxt
  let fix = "returning just the condition"
  let violation = "returning the condition of an if statement on success and false otherwise"
  let check st (E {location; source; pattern} : ctxt) =
    begin match pattern with
      | Pexp_ifthenelse (cond, bthen, Some belse) ->
        if are_idents_same cond bthen && belse =| "false" then
               st := Hint.mk_hint location source fix violation :: !st
      | _ -> ()
    end
end


module IfNotCond : EXPRCHECK = struct
  type ctxt = Parsetree.expression_desc Pctxt.pctxt
  let fix = "swapping the then and else branches of the if statement"
  let violation = "checking negation in the if condition"
  let check st (E {location; source; pattern} : ctxt) =
    begin match pattern with
      | Pexp_ifthenelse (cond, _, _) ->
        begin match cond.pexp_desc with
          | Pexp_apply (func, [_]) -> if func =~ "not" then
              st := Hint.mk_hint location source fix violation :: !st
          | _ -> ()
        end
      | _ -> ()
    end
end

module IfToOr : EXPRCHECK = struct
  type ctxt = Parsetree.expression_desc Pctxt.pctxt
  let fix = "rewriting using a boolean operator like `||`"
  let violation = "overly verbose if statement that can be simplified"
    
  let check st (E {location; source; pattern} : ctxt) =
    begin match pattern with
      | Pexp_ifthenelse (cond, bthen, Some belse) ->
        if is_exp_id cond && is_exp_id belse && bthen =| "true" then
          st := Hint.mk_hint location source fix violation :: !st
      | _ -> ()
    end
end

module IfToAnd : EXPRCHECK = struct
  type ctxt = Parsetree.expression_desc Pctxt.pctxt
  let fix = "rewriting using a boolean operator like `&&`"
  let violation = "overly verbose if statement that can be simplified"
    
  let check st (E {location; source; pattern} : ctxt) =
    begin match pattern with
      | Pexp_ifthenelse (cond, bthen, Some belse) ->
        if is_exp_id cond && is_exp_id bthen && belse =| "false" then
          st := Hint.mk_hint location source fix violation :: !st
      | _ -> ()
    end
end

module IfToAndInv : EXPRCHECK = struct
  type ctxt = Parsetree.expression_desc Pctxt.pctxt
  let fix = "rewariting using a boolean operator like `&&` and `not`"
  let violation = "overly verbose if statement that can be simplified"
  let check st (E {location;source;pattern} : ctxt) =
    begin match pattern with
      | Pexp_ifthenelse (cond, bthen, Some belse) ->
        if is_exp_id cond && is_exp_id belse && bthen =| "false" then
          st := Hint.mk_hint location source fix violation :: !st
      | _ -> ()
    end
end

module IfToOrInv : EXPRCHECK = struct
  type ctxt = Parsetree.expression_desc Pctxt.pctxt
  let fix = "rewariting using a boolean operator like `||` and `not`"
  let violation = "overly verbose if statement that can be simplified"
  let check st (E {location; source; pattern} : ctxt) =
    begin match pattern with
      | Pexp_ifthenelse (cond, bthen, Some belse) ->
        if is_exp_id cond && is_exp_id bthen && belse =| "true" then
          st := Hint.mk_hint location source fix violation :: !st
      | _ -> ()
    end
  
end
