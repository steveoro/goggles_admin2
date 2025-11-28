#!/usr/bin/env python3
import json
import argparse
import sys
import os
import re

def build_interest_tree(node, query):
    """
    Recursively searches the node for the query string.
    Returns (has_match, interest_tree)
    interest_tree is a dict where keys are children keys/indices that lead to a match.
    """
    if isinstance(node, str):
        if query in node:
            return True, {}
        return False, {}
    
    if isinstance(node, dict):
        my_interest = {}
        has_match = False
        for key, value in node.items():
            child_match, child_tree = build_interest_tree(value, query)
            if child_match:
                my_interest[key] = child_tree
                has_match = True
        return has_match, my_interest

    if isinstance(node, list):
        my_interest = {}
        has_match = False
        for i, value in enumerate(node):
            child_match, child_tree = build_interest_tree(value, query)
            if child_match:
                my_interest[i] = child_tree
                has_match = True
        return has_match, my_interest
        
    # Other types (int, float, bool, None)
    # Convert to string to check? User said "string value contains the query string".
    # Let's stick to strings for now, or maybe cast leaf nodes to string?
    # "if the string value contains the query string" -> implies checking string values.
    # But if user searches for "123" and value is 123 (int), should it match?
    # Let's assume strict string matching for now as per request "string value".
    return False, {}

def highlight_match(text, query):
    if not query:
        return text
    # Green ANSI code
    green = "\033[92m"
    reset = "\033[0m"
    return text.replace(query, f"{green}{query}{reset}")

def process_dict_children(node, current_path, depth, target_path, prefix, interest_tree=None, query=None):
    keys = list(node.keys())
    
    # Grouping Logic
    groups = {} # Key: (num_pipes, num_dashes, separator, child_keys) -> Value: [list of keys]
    non_grouped_keys = []
    
    # Identify next step in target path to avoid hiding it in a group
    next_target_key = None
    if target_path and len(target_path) > len(current_path):
        next_target_key = target_path[len(current_path)]

    for key in keys:
        # If we have an interest tree, only process keys in it
        if interest_tree is not None and key not in interest_tree:
            continue

        # Check if this key is the next step in target path
        if key == next_target_key:
            non_grouped_keys.append(key)
            continue
            
        # If this key is interesting (part of query result), do not group it
        # to ensure we can see the match inside.
        if interest_tree is not None and key in interest_tree:
            non_grouped_keys.append(key)
            continue

        is_candidate = False
        if isinstance(key, str):
            if isinstance(node[key], dict):
                is_candidate = True
        
        if is_candidate:
            # Count valid pipes: (?<=\S)\|(?=\S)
            valid_pipes = len(re.findall(r'(?<=\S)\|(?=\S)', key))
            
            num_pipes = 0
            num_dashes = 0
            separator = None
            
            if valid_pipes > 0:
                num_pipes = valid_pipes
                separator = '|'
            else:
                # Count valid dashes: (?<=\S)\-(?=\S)
                valid_dashes = len(re.findall(r'(?<=\S)\-(?=\S)', key))
                if valid_dashes > 0:
                    num_dashes = valid_dashes
                    separator = '-'
            
            child_keys = frozenset(node[key].keys())
            # Group ID: (num_pipes, num_dashes, separator, child_keys)
            group_id = (num_pipes, num_dashes, separator, child_keys)
            
            if group_id not in groups:
                groups[group_id] = []
            groups[group_id].append(key)
        else:
            non_grouped_keys.append(key)
    
    # Process groups: if a group has only 1 item, move it to non_grouped_keys
    final_groups = {}
    for group_id, group_keys in groups.items():
        if len(group_keys) > 1:
            final_groups[group_id] = group_keys
        else:
            non_grouped_keys.extend(group_keys)
    
    all_items_to_process = []
    
    # Add non-grouped
    for k in non_grouped_keys:
        all_items_to_process.append({'type': 'single', 'key': k})
        
    # Add groups
    for group_id, group_keys in final_groups.items():
        all_items_to_process.append({'type': 'group', 'keys': group_keys, 'id': group_id})
        
    # Sort by string representation
    all_items_to_process.sort(key=lambda x: str(x['key']) if x['type'] == 'single' else str(x['keys'][0]))

    for i, item in enumerate(all_items_to_process):
        is_last_child = (i == len(all_items_to_process) - 1)
        
        if item['type'] == 'single':
            key = item['key']
            child_interest = None
            if interest_tree is not None:
                child_interest = interest_tree.get(key)
            
            print_tree(node[key], current_path + [key], depth + 1, target_path, is_last_child, prefix, interest_tree=child_interest, query=query)
        else:
            # Print group representative
            group_keys = item['keys']
            first_key = group_keys[0]
            num_pipes = item['id'][0]
            num_dashes = item['id'][1]
            separator = item['id'][2]
            
            # Construct label: "<fld1>|<fld2>..."
            if separator:
                count = num_pipes if separator == '|' else num_dashes
                fields = ["<fld{}>".format(j+1) for j in range(count + 1)]
                label_pattern = separator.join(fields)
            else:
                # No separator (e.g. simple keys grouped by structure)
                label_pattern = "<fld1>"
            
            group_label = f'"{label_pattern}" (ex.: "{first_key}")'
            
            connector = "+--- " if is_last_child else "+--- "
            print(f"{prefix}{connector}{group_label}")
            
            # Recurse on the first key as representative
            # We need to adjust the prefix for the child
            grand_child_prefix = prefix
            if is_last_child:
                grand_child_prefix += "    "
            else:
                grand_child_prefix += "|   "

            representative_node = node[first_key]
            
            # Recursively process the children of the representative node
            # using the same grouping logic
            # Note: Grouping logic implies we don't have specific interest inside the group 
            # (because we excluded interesting keys from groups), so interest_tree is likely None or irrelevant here?
            # Actually, if we grouped them, it means none of them were in interest_tree (if query is active).
            # So we can pass None for interest_tree.
            
            if isinstance(representative_node, dict):
                process_dict_children(representative_node, current_path + [first_key], depth + 1, target_path, grand_child_prefix, interest_tree=None, query=query)
            elif isinstance(representative_node, list):
                 pass

def print_tree(node, current_path=None, depth=0, target_path=None, is_last=True, prefix="", interest_tree=None, query=None):
    if current_path == None:
        current_path = []
    
    # Determine if we are on the target path
    on_target_path = True
    if target_path:
        # Check if current_path matches the beginning of target_path
        if len(current_path) > len(target_path):
             on_target_path = False
        else:
             for i in range(len(current_path)):
                 if current_path[i] != target_path[i]:
                     on_target_path = False
                     break

    # Prepare the node label
    node_label = ""
    if depth == 0:
        node_label = "[root]"
    else:
        key = current_path[-1]
        if isinstance(key, int):
            node_label = f"[{key}]"
        else:
            node_label = str(key)

    # Highlight if this is the exact target
    if target_path and current_path == target_path:
        node_label += " <--- TARGET"
        
    # If query is active and this node is a string match, append the value
    if query and isinstance(node, str) and query in node:
        highlighted_val = highlight_match(node, query)
        node_label += f": {highlighted_val}"

    # Print the current node
    connector = ""
    if depth > 0:
        connector = "+--- " if is_last else "+--- "
    
    print(f"{prefix}{connector}{node_label}")

    # Prepare prefix for children
    child_prefix = prefix
    if depth > 0:
        child_prefix += "    " if is_last else "|   "
    else:
        child_prefix = "     "

    # Recurse
    if isinstance(node, dict):
        process_dict_children(node, current_path, depth, target_path, child_prefix, interest_tree=interest_tree, query=query)

    elif isinstance(node, list):
        if not node:
            return

        indices_to_visit = []
        
        if query and interest_tree is not None:
            # Only visit indices in interest_tree
            indices_to_visit = sorted([i for i in interest_tree.keys() if isinstance(i, int)])
        else:
            # Default logic
            next_target_index = -1
            if target_path and len(target_path) > len(current_path):
                 # Check if the next item in target_path is an integer (index)
                 next_step = target_path[len(current_path)]
                 if isinstance(next_step, int):
                     next_target_index = next_step

            if next_target_index != -1:
                if 0 <= next_target_index < len(node):
                    indices_to_visit.append(next_target_index)
                else:
                    indices_to_visit.append(0)
            else:
                # Default to index 0
                indices_to_visit.append(0)
            
        for i, index in enumerate(indices_to_visit):
            is_last_child = (i == len(indices_to_visit) - 1)
            child_interest = None
            if interest_tree is not None:
                child_interest = interest_tree.get(index)
                
            print_tree(node[index], current_path + [index], depth + 1, target_path, is_last_child, child_prefix, interest_tree=child_interest, query=query)

def main():
    parser = argparse.ArgumentParser(description="Visualize JSON structure as an ASCII tree. Test it with: 'bin/json_tree_viewer.py crawler/test/test_grouping.json'")
    parser.add_argument("file_path", help="Path to the JSON file")
    parser.add_argument("--path", help="JSON string representing the path to follow (e.g., '[\"sections\", 22]')", default=None)
    parser.add_argument("-q", "--query", help="Search for a string value and focus the tree on matches", default=None)

    args = parser.parse_args()

    try:
        with open(args.file_path, 'r') as f:
            data = json.load(f)
    except Exception as e:
        print(f"Error loading JSON file: {e}", file=sys.stderr)
        sys.exit(1)

    target_path = None
    if args.path:
        try:
            target_path = json.loads(args.path)
            if not isinstance(target_path, list):
                raise ValueError("Path must be a JSON list")
        except Exception as e:
            print(f"Error parsing path: {e}", file=sys.stderr)
            sys.exit(1)
            
    interest_tree = None
    if args.query:
        has_match, interest_tree = build_interest_tree(data, args.query)
        if not has_match:
            print(f"No matches found for query: '{args.query}'")
            return

    print_tree(data, target_path=target_path, interest_tree=interest_tree, query=args.query)

if __name__ == "__main__":
    main()
